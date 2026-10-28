import AppKit
import MarkdownCore
import os

/// Owns the file open in the editor: loading, debounced autosave, and external changes.
///
/// Data-safety rules:
/// - A failed save keeps the buffer dirty and is reported (`onSaveFailure`); nothing that would
///   discard the buffer (switching file or folder, closing, quitting) proceeds until a save
///   succeeds or `confirmDiscard` says the user chose to throw the edits away.
/// - A file that is deleted, or moved to the Trash, is closed — never recreated or edited in
///   the Trash (`onClosedExternally`).
/// - External changes are read under coordination and only when the modification date moved;
///   a clean buffer reloads, a dirty one keeps its text (next save wins).
/// - The file is written back in the encoding it was read in; symlinks save through to their
///   target.
final class FileSession: NSObject, NSFilePresenter, @unchecked Sendable {
    static let autosaveDelay: TimeInterval = 1.0
    private static let log = Logger(subsystem: "com.chri5tian.markdown-editor", category: "session")

    private let editor: EditorViewController
    private let lock = NSLock()
    private nonisolated(unsafe) var _url: URL?
    @MainActor private(set) var lastSavedText = ""
    @MainActor private(set) var isDirty = false
    @MainActor private(set) var encoding: String.Encoding = .utf8
    @MainActor private var lastModificationDate: Date?
    /// The error from the most recent save attempt, nil once a save succeeds.
    @MainActor private(set) var lastSaveError: Error?
    @MainActor private var saveTimer: Timer?
    /// The write used by `save()`; replaceable in tests to inject failures.
    @MainActor var writer: (String, URL, String.Encoding, NSFilePresenter) throws -> Void = { text, url, encoding, presenter in
        try FileStore.write(text, to: url, encoding: encoding, createIfMissing: false, presenter: presenter)
    }

    /// A save failed. `firstInStreak` is true for the first failure after a success.
    @MainActor var onSaveFailure: ((Error, _ firstInStreak: Bool) -> Void)?
    /// A save succeeded after one or more failures.
    @MainActor var onSaveRecovered: (() -> Void)?
    /// Asked before unsaved (unsaveable) edits would be dropped; return true to discard them.
    /// Unset means "never discard".
    @MainActor var confirmDiscard: ((Error) -> Bool)?
    /// The open file was deleted or trashed and has been closed. Argument: its last URL.
    @MainActor var onClosedExternally: ((URL) -> Void)?
    /// The open file was renamed or moved (not to the Trash).
    @MainActor var onMoved: ((URL) -> Void)?
    /// Reading a file failed.
    @MainActor var onReadFailure: ((URL, Error) -> Void)?

    @MainActor init(editor: EditorViewController) {
        self.editor = editor
        super.init()
        editor.onTextChange = { [weak self] in self?.textDidChange() }
    }

    var currentURL: URL? {
        lock.lock(); defer { lock.unlock() }
        return _url
    }

    private func setURL(_ url: URL?) {
        lock.lock(); _url = url; lock.unlock()
    }

    // MARK: Open / close

    /// Opens `url`, saving the current file first. Returns false (and stays put) when the
    /// current edits cannot be saved and the user keeps them, or when `url` cannot be read.
    @MainActor @discardableResult
    func open(_ url: URL) -> Bool {
        guard !ImageFile.isImage(url) else { return false }   // images go to the viewer, never into the text buffer
        let url = url.standardizedFileURL
        if url == currentURL { return true }
        let contents: FileContents
        do {
            contents = try FileStore.readCoordinated(url)
        } catch {
            Self.log.error("read failed \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            onReadFailure?(url, error)
            return false
        }
        guard prepareToLeave() else { return false }
        detach()
        setURL(url)
        lastSavedText = contents.text
        encoding = contents.encoding
        lastModificationDate = contents.modificationDate
        isDirty = false
        lastSaveError = nil
        editor.baseURL = url.deletingLastPathComponent()
        editor.load(contents.text)
        NSFileCoordinator.addFilePresenter(self)
        return true
    }

    /// Saves and forgets the current file (folder switch). Returns false if it must stay open.
    @MainActor @discardableResult
    func close() -> Bool {
        guard prepareToLeave() else { return false }
        forget()
        return true
    }

    /// True when the buffer may be dropped: it saved, it was clean, or the user chose to discard.
    /// A discard puts the editor back to the last saved text at once, so a caller that then stays
    /// on this note (⌘N whose create fails) never shows the discarded text as if it were clean —
    /// where the next keystroke would autosave it back.
    @MainActor func prepareToLeave() -> Bool {
        if save() { return true }
        let error = lastSaveError ?? CocoaError(.fileWriteUnknown)
        guard confirmDiscard?(error) ?? false else { return false }
        Self.log.info("unsaved edits to \(self.currentURL?.path ?? "?", privacy: .public) discarded by the user")
        isDirty = false
        lastSaveError = nil
        editor.load(lastSavedText, selection: editor.textView.selectedRange())
        return true
    }

    @MainActor private func forget() {
        detach()
        setURL(nil)
        lastSavedText = ""
        isDirty = false
        lastSaveError = nil
        lastModificationDate = nil
    }

    @MainActor private func detach() {
        saveTimer?.invalidate()
        saveTimer = nil
        if currentURL != nil { NSFileCoordinator.removeFilePresenter(self) }
    }

    // MARK: Saving

    @MainActor private func textDidChange() {
        guard currentURL != nil else { return }
        isDirty = true
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: Self.autosaveDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.save() }
        }
    }

    /// Writes the buffer if it has unsaved edits. Never prompts. Returns true when nothing is
    /// left unsaved. On failure the buffer stays dirty and `onSaveFailure` fires.
    @MainActor @discardableResult
    func save() -> Bool {
        saveTimer?.invalidate()
        saveTimer = nil
        guard isDirty, let url = currentURL else { return true }
        let text = editor.text
        do {
            try writer(text, url, encoding, self)
            lastSavedText = text
            lastModificationDate = FileStore.modificationDate(url)
            isDirty = false
            if lastSaveError != nil {
                lastSaveError = nil
                onSaveRecovered?()
            }
            ProbeLog.shared.dump()
            return true
        } catch let error as CocoaError where error.code == .fileNoSuchFile
                    && !FileManager.default.fileExists(atPath: url.path) {
            // Deleted behind our back without a coordinated delete: close, don't recreate.
            // (A "no such file" error while the note still exists falls through to the
            // failed-save path below, so the text is kept.)
            Self.log.info("\(url.path, privacy: .public) no longer exists; closing it")
            closeExternally(url)
            return true
        } catch {
            Self.log.error("save failed \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            let first = lastSaveError == nil
            lastSaveError = error
            onSaveFailure?(error, first)
            ProbeLog.shared.dump()
            return false
        }
    }

    @MainActor private func closeExternally(_ url: URL) {
        forget()
        onClosedExternally?(url)
        ProbeLog.shared.dump()
    }

    // MARK: NSFilePresenter

    var presentedItemURL: URL? { currentURL }
    let presentedItemOperationQueue: OperationQueue = .main

    func presentedItemDidChange() {
        MainActor.assumeIsolated { reloadFromDisk() }
    }

    func presentedItemDidMove(to newURL: URL) {
        MainActor.assumeIsolated { handleMove(to: newURL.standardizedFileURL) }
    }

    func accommodatePresentedItemDeletion(completionHandler: @escaping @Sendable (Error?) -> Void) {
        MainActor.assumeIsolated {
            if let url = currentURL { closeExternally(url) }
        }
        completionHandler(nil)
    }

    @MainActor func handleMove(to newURL: URL) {
        guard let old = currentURL else { return }
        if Self.isInTrash(newURL) {
            closeExternally(old)
            return
        }
        setURL(newURL)
        editor.baseURL = newURL.deletingLastPathComponent()
        onMoved?(newURL)
    }

    static func isInTrash(_ url: URL) -> Bool {
        if let trash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: url, create: false),
           url.standardizedFileURL.path.hasPrefix(trash.standardizedFileURL.path + "/") {
            return true
        }
        return url.pathComponents.contains(".Trash") || url.pathComponents.contains(".Trashes")
    }

    /// Reloads a changed file into a clean buffer. Reads under coordination and only when the
    /// modification date moved; a dirty buffer keeps its text (next save wins).
    @MainActor func reloadFromDisk() {
        guard let url = currentURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            closeExternally(url)
            return
        }
        let date = FileStore.modificationDate(url)
        if let date, let last = lastModificationDate, date == last { return }
        guard let contents = try? FileStore.readCoordinated(url, presenter: self) else { return }
        lastModificationDate = contents.modificationDate
        guard contents.text != lastSavedText else { return }
        if isDirty {
            Self.log.info("external change to \(url.path, privacy: .public) ignored: unsaved edits win")
            return
        }
        let selection = editor.textView.selectedRange()
        lastSavedText = contents.text
        encoding = contents.encoding
        editor.load(contents.text, selection: selection)
    }
}
