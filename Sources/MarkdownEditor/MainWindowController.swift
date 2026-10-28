import AppKit
import MarkdownCore
import UniformTypeIdentifiers

/// The one main window: sidebar folder tree + editor, and every "open this" path.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    static let lastFolderKey = "lastFolder"
    static let lastFileKey = "lastFile"

    let splitViewController = NSSplitViewController()
    let sidebar = SidebarViewController()
    let editor = EditorViewController()
    private(set) lazy var session = FileSession(editor: editor)
    private(set) var folder: URL?
    /// The image file the pane is showing (nil while a note or nothing is shown).
    private(set) var viewedImage: URL?
    /// Its modification date when shown: an FSEvents batch reloads it only when this moved.
    private var viewedImageDate: Date?

    /// The app's one theme, handed to every view that draws with it.
    let theme: Theme

    init(theme: Theme = Theme()) {
        self.theme = theme
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: theme.defaultWindowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Markdown Editor"
        window.isRestorable = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        editor.styler.theme = theme
        sidebar.theme = theme

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = theme.sidebarMinWidth
        sidebarItem.maximumThickness = theme.sidebarMaxWidth
        sidebarItem.canCollapse = true
        let editorItem = NSSplitViewItem(viewController: editor)
        editorItem.minimumThickness = theme.editorMinWidth
        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(editorItem)
        splitViewController.splitView.autosaveName = "MainSplit"

        let drop = DropView(frame: NSRect(origin: .zero, size: theme.defaultWindowSize))
        drop.theme = theme
        let split = splitViewController.view
        split.frame = drop.bounds
        split.autoresizingMask = [.width, .height]
        drop.addSubview(split)
        drop.onOpen = { [weak self] url in self?.open(url) }
        let root = NSViewController()
        root.view = drop
        root.addChild(splitViewController)
        window.contentViewController = root
        window.setContentSize(theme.defaultWindowSize)
        window.center()
        window.setFrameAutosaveName("MainWindow")

        editor.onOpen = { [weak self] url in self?.open(url) }
        sidebar.onSelectFile = { [weak self] url in
            guard let self else { return }
            self.openFile(url, focusEditor: !self.sidebar.selectionByKeys)   // arrowing keeps focus in the sidebar (decision 39)
        }
        configureSession()
        editor.onImageLoad = { [weak self] info in self?.imageLoaded(info) }
        sidebar.onFilesChanged = { [weak self] paths in self?.viewedImageMayHaveChanged(paths) }
        ProbeLog.shared.window = self
    }

    private func configureSession() {
        session.onSaveFailure = { [weak self] error, first in self?.saveFailed(error, first: first) }
        session.onSaveRecovered = { [weak self] in self?.updateSubtitle() }
        session.confirmDiscard = { [weak self] error in self?.askToDiscard(error) ?? false }
        session.onClosedExternally = { [weak self] url in self?.fileClosedExternally(url) }
        session.onMoved = { [weak self] url in
            UserDefaults.standard.set(url.path, forKey: Self.lastFileKey)
            self?.updateSubtitle()
        }
        session.onReadFailure = { [weak self] url, error in
            guard let window = self?.window else { return }
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn’t open “\(url.lastPathComponent)”"
            alert.informativeText = error.localizedDescription
            alert.beginSheetModal(for: window)
            self?.sidebar.selectFile(self?.session.currentURL ?? self?.viewedImage)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Opening

    /// Every open path lands here: a folder, or a markdown or image file. A file inside the current root
    /// is selected in place; a file elsewhere opens its parent folder as the new root.
    /// Returns false when nothing changed (unopenable URL, or unsaved edits kept).
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let target = OpenTarget.resolve(url) else { return false }
        if let file = target.file, let root = folder, file.path.hasPrefix(root.path + "/") {
            sidebar.reveal(file)
            openFile(file)
            ProbeLog.shared.dump()
            return true
        }
        if target.folder != folder {
            guard setFolder(target.folder) else { return false }
        }
        if let file = target.file {
            sidebar.reveal(file)
            openFile(file)
        }
        ProbeLog.shared.dump()
        return true
    }

    @discardableResult
    private func setFolder(_ url: URL) -> Bool {
        guard session.close() else { return false }
        folder = url
        window?.title = url.lastPathComponent
        window?.representedURL = url
        sidebar.setRoot(url)
        viewedImage = nil
        viewedImageDate = nil
        editor.showEmpty("Select a file")
        updateSubtitle()
        UserDefaults.standard.set(url.path, forKey: Self.lastFolderKey)
        UserDefaults.standard.removeObject(forKey: Self.lastFileKey)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        return true
    }

    @discardableResult
    private func openFile(_ url: URL, focusEditor: Bool = true) -> Bool {
        if ImageFile.isImage(url) { return showImage(url) }
        guard session.open(url) else {
            sidebar.selectFile(session.currentURL ?? viewedImage)   // put the selection back on what is shown
            return false
        }
        viewedImage = nil
        viewedImageDate = nil
        updateSubtitle()
        UserDefaults.standard.set(url.standardizedFileURL.path, forKey: Self.lastFileKey)
        if focusEditor { editor.focus() }   // false only for plain-key navigation in the sidebar (decision 39)
        ProbeLog.shared.dump()
        return true
    }

    // MARK: Images

    /// Shows an image read-only. Leaving the open note follows the same rule as switching notes:
    /// it is saved, or the user explicitly discards, or nothing changes.
    @discardableResult
    private func showImage(_ url: URL) -> Bool {
        let url = url.standardizedFileURL
        if url.path == viewedImage?.path, editor.isShowingImage { return true }
        guard session.close() else {
            sidebar.selectFile(session.currentURL)
            return false
        }
        viewedImage = url
        viewedImageDate = FileStore.modificationDate(url)
        editor.showImage(url)
        updateSubtitle()
        UserDefaults.standard.set(url.path, forKey: Self.lastFileKey)
        window?.makeFirstResponder(sidebar.outlineView)   // arrow keys keep stepping through the folder
        ProbeLog.shared.dump()
        return true
    }

    private func imageLoaded(_ info: ImageFile.Info?) {
        guard let image = viewedImage else { return }
        if info == nil { editor.showEmpty("“\(image.lastPathComponent)” can’t be displayed") }
        updateSubtitle()
        ProbeLog.shared.dump()
    }

    /// FSEvents batch from the sidebar: the image on screen may have been deleted, renamed or rewritten.
    func viewedImageMayHaveChanged(_ paths: [String]) {
        guard let image = viewedImage else { return }
        guard FileManager.default.fileExists(atPath: image.path) else {
            viewedImage = nil
            viewedImageDate = nil
            editor.showEmpty("“\(image.lastPathComponent)” is no longer in the folder")   // deleted, trashed or renamed
            sidebar.selectFile(nil)
            updateSubtitle()
            UserDefaults.standard.removeObject(forKey: Self.lastFileKey)
            return
        }
        let target = image.resolvingSymlinksInPath().path
        guard paths.contains(where: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == target }) else { return }
        let date = FileStore.modificationDate(image)
        guard date != viewedImageDate else { return }   // metadata-only event (xattrs): keep the zoom (decision 37)
        viewedImageDate = date
        editor.showImage(image)   // rewritten in place: show the new pixels
    }

    // MARK: New note

    /// File › New. With a folder open: creates the next free `Untitled.md` in the folder the
    /// sidebar selection is in (else the open file's or shown image's folder, else the root), selects it and puts
    /// the cursor in it. With no folder: a Save panel picks the file, and its folder opens.
    func newNote() {
        guard let root = folder else { newNoteWithSavePanel(); return }
        // Save (or explicitly discard) the current note first, so a refused switch leaves no new file.
        guard session.prepareToLeave() else { return }
        // Only ever inside the open folder: the open note may have been moved out of it (Finder),
        // and the session follows a moved note.
        let candidate = sidebar.selectedDirectory
            ?? session.currentURL?.deletingLastPathComponent().standardizedFileURL
            ?? viewedImage?.deletingLastPathComponent().standardizedFileURL
            ?? root
        let dir = Self.isInside(candidate, root) ? candidate : root
        let url: URL
        do {
            url = try FileStore.createNew(in: dir, presenter: session)
        } catch {
            showCreateError(error, in: dir)
            return
        }
        sidebar.refresh(directory: dir)
        sidebar.reveal(url)
        openFile(url)
        ProbeLog.shared.dump()
    }

    /// True when `dir` is `root` or below it (compared standardized, symlinks resolved).
    static func isInside(_ dir: URL, _ root: URL) -> Bool {
        let d = dir.standardizedFileURL.resolvingSymlinksInPath().path
        let r = root.standardizedFileURL.resolvingSymlinksInPath().path
        return d == r || d.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }

    private func newNoteWithSavePanel() {
        guard session.prepareToLeave() else { return }
        let panel = NSSavePanel()
        panel.title = "New Note"
        panel.nameFieldStringValue = FileStore.untitledName(1)
        panel.allowedContentTypes = FolderTree.markdownExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.canCreateDirectories = true
        panel.prompt = "Create"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FileStore.createExclusively(url, presenter: session)
        } catch CocoaError.fileWriteFileExists {
            // The user chose an existing file and confirmed in the panel: open it, never empty it.
        } catch {
            showCreateError(error, in: url.deletingLastPathComponent())
            return
        }
        open(url)
    }

    private func showCreateError(_ error: Error, in dir: URL) {
        guard let window else { return }
        let alert = NSAlert(error: error)
        alert.messageText = "Couldn’t create a new note in “\(dir.lastPathComponent)”"
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    /// Reopens the folder from the previous run as the root, and selects the last file in it
    /// only if that file still exists inside that folder.
    func restoreLastSession() {
        let defaults = UserDefaults.standard
        guard let folderPath = defaults.string(forKey: Self.lastFolderKey),
              let target = OpenTarget.resolve(URL(fileURLWithPath: folderPath)), target.file == nil else { return }
        let filePath = defaults.string(forKey: Self.lastFileKey)
        guard setFolder(target.folder) else { return }
        guard let file = OpenTarget.restorableFile(filePath, in: target.folder) else { return }
        sidebar.reveal(file)
        openFile(file)
    }

    @discardableResult
    func save() -> Bool { session.save() }

    /// True when the window may close / the app may quit without losing edits.
    func prepareToClose() -> Bool { session.prepareToLeave() }

    // MARK: Save problems

    private func updateSubtitle() {
        if let image = viewedImage {
            window?.subtitle = editor.imageViewer.info.map { ImageFile.subtitle(name: image.lastPathComponent, info: $0) }
                ?? image.lastPathComponent
            return
        }
        guard let url = session.currentURL else { window?.subtitle = ""; return }
        if let error = session.lastSaveError {
            window?.subtitle = "\(url.lastPathComponent) — Not saved: \(error.localizedDescription)"
        } else {
            window?.subtitle = url.lastPathComponent
        }
    }

    private func saveFailed(_ error: Error, first: Bool) {
        updateSubtitle()
        guard first, let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Your changes couldn’t be saved"
        alert.informativeText = "\(error.localizedDescription)\n\nThe text stays in the editor, and saving is retried as you type. You can’t switch files until it saves or you discard the changes."
        alert.beginSheetModal(for: window)
    }

    /// Modal: the only way to drop unsaved edits is an explicit "Discard Changes".
    private func askToDiscard(_ error: Error) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        let name = session.currentURL?.lastPathComponent ?? "this note"
        alert.messageText = "“\(name)” has changes that couldn’t be saved"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard Changes")
        if let sheet = window?.attachedSheet { window?.endSheet(sheet) }
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func fileClosedExternally(_ url: URL) {
        editor.showEmpty("“\(url.lastPathComponent)” was deleted or moved to the Trash")
        sidebar.selectFile(nil)
        updateSubtitle()
        UserDefaults.standard.removeObject(forKey: Self.lastFileKey)
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool { prepareToClose() }
    func windowWillClose(_ notification: Notification) { session.save() }
    func windowDidResignKey(_ notification: Notification) { session.save() }

    // MARK: Probe hook

    func probeState() -> [String: Any] {
        let tv = editor.textView!
        let sel = tv.selectedRange()
        return [
            "title": window?.title ?? "",
            "subtitle": window?.subtitle ?? "",
            "folder": folder?.path ?? "",
            "file": session.currentURL?.path ?? "",
            "selectedRow": sidebar.selectedFile?.lastPathComponent ?? "",
            "rows": sidebar.visibleRowNames,
            "dirty": session.isDirty,
            "saveError": session.lastSaveError?.localizedDescription ?? "",
            "selection": [sel.location, sel.length],
            "editorIsFirstResponder": window?.firstResponder === tv,
            "text": editor.text,
            "image": viewedImage?.path ?? "",
            "imageSize": editor.imageViewer.info.map { [$0.pixelWidth, $0.pixelHeight] } ?? [],
            "magnification": Double(editor.imageViewer.scrollView.magnification),
        ]
    }

    func runProbeCommand(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let cmd = parts.first else { return }
        let arg = parts.count > 1 ? parts[1] : ""
        let tv = editor.textView!
        switch cmd {
        case "type":
            tv.insertText(arg, replacementRange: tv.selectedRange())
        case "key":
            switch arg {
            case "return": tv.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            case "tab": tv.doCommand(by: #selector(NSResponder.insertTab(_:)))
            case "backtab": tv.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
            default: break
            }
        case "select":
            let n = arg.split(separator: " ").compactMap { Int($0) }
            if n.count == 2 { tv.setSelectedRange(NSRange(location: n[0], length: n[1])) }
        case "action":
            // "action setHeadingLevel: 2" passes the number as the sender (menu items use tags).
            let bits = arg.split(separator: " ")
            let sender: Any? = bits.count > 1 ? NSNumber(value: Int(bits[1]) ?? 0) : nil
            // Walk this window's responder chain: NSApp.sendAction(to: nil) needs a key window,
            // which a probe-launched (inactive) app does not have. App-level actions (newDocument:)
            // live on the app delegate, past that chain: fall back to NSApp's own dispatch.
            let action = Selector(String(bits[0]))
            if window?.firstResponder?.tryToPerform(action, with: sender) != true {
                NSApp.sendAction(action, to: nil, from: sender)
            }
        case "row":
            let names = sidebar.visibleRowNames.map { $0.trimmingCharacters(in: .whitespaces) }
            if let row = names.firstIndex(of: arg) {
                sidebar.outlineView.selectRowIndexes([row], byExtendingSelection: false)
            }
        case "open":
            open(URL(fileURLWithPath: arg))
        case "snapshot":
            // Renders the window's content in-process (no Screen Recording permission needed).
            guard let view = window?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
        default:
            break
        }
    }
}
