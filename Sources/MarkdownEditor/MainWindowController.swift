import AppKit
import MarkdownCore

/// The one main window: sidebar folder tree + editor, and every "open this" path.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    static let lastFolderKey = "lastFolder"
    static let lastFileKey = "lastFile"

    let splitViewController = NSSplitViewController()
    let sidebar = SidebarViewController()
    let editor = EditorViewController()
    private(set) lazy var session = FileSession(editor: editor)
    private(set) var folder: URL?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 750),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Markdown Editor"
        window.isRestorable = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 420
        sidebarItem.canCollapse = true
        let editorItem = NSSplitViewItem(viewController: editor)
        editorItem.minimumThickness = 320
        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(editorItem)
        splitViewController.splitView.autosaveName = "MainSplit"

        let drop = DropView(frame: NSRect(x: 0, y: 0, width: 1100, height: 750))
        let split = splitViewController.view
        split.frame = drop.bounds
        split.autoresizingMask = [.width, .height]
        drop.addSubview(split)
        drop.onOpen = { [weak self] url in self?.open(url) }
        let root = NSViewController()
        root.view = drop
        root.addChild(splitViewController)
        window.contentViewController = root
        window.setContentSize(NSSize(width: 1100, height: 750))
        window.center()
        window.setFrameAutosaveName("MainWindow")

        editor.onOpen = { [weak self] url in self?.open(url) }
        sidebar.onSelectFile = { [weak self] url in self?.openFile(url) }
        configureSession()
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
            self?.sidebar.selectFile(self?.session.currentURL)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Opening

    /// Every open path lands here: a folder, or a markdown file. A file inside the current root
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
        editor.showEmpty("Select a file")
        updateSubtitle()
        UserDefaults.standard.set(url.path, forKey: Self.lastFolderKey)
        UserDefaults.standard.removeObject(forKey: Self.lastFileKey)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        return true
    }

    @discardableResult
    private func openFile(_ url: URL) -> Bool {
        guard session.open(url) else {
            sidebar.selectFile(session.currentURL)   // put the selection back on the open file
            return false
        }
        updateSubtitle()
        UserDefaults.standard.set(url.standardizedFileURL.path, forKey: Self.lastFileKey)
        editor.focus()
        ProbeLog.shared.dump()
        return true
    }

    /// Reopens the folder from the previous run as the root, and selects the last file in it
    /// only if that file still exists inside that folder.
    func restoreLastSession() {
        let defaults = UserDefaults.standard
        guard let folderPath = defaults.string(forKey: Self.lastFolderKey),
              let target = OpenTarget.resolve(URL(fileURLWithPath: folderPath)), target.file == nil else { return }
        let filePath = defaults.string(forKey: Self.lastFileKey)
        guard setFolder(target.folder) else { return }
        guard let filePath else { return }
        let file = URL(fileURLWithPath: filePath).standardizedFileURL
        guard file.path.hasPrefix(target.folder.path + "/"), FolderTree.isMarkdown(file),
              FileManager.default.fileExists(atPath: file.path) else { return }
        sidebar.reveal(file)
        openFile(file)
    }

    @discardableResult
    func save() -> Bool { session.save() }

    /// True when the window may close / the app may quit without losing edits.
    func prepareToClose() -> Bool { session.prepareToLeave() }

    // MARK: Save problems

    private func updateSubtitle() {
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
            // which a probe-launched (inactive) app does not have.
            _ = window?.firstResponder?.tryToPerform(Selector(String(bits[0])), with: sender)
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
