import AppKit
import MarkdownCore
import UniformTypeIdentifiers

/// Menu actions with no AppKit declaration, so `#selector` can name them.
@MainActor @objc protocol EditorMenuActions {
    func newDocument(_ sender: Any?)
    func openDocument(_ sender: Any?)
    func saveDocument(_ sender: Any?)
    func checkForUpdates(_ sender: Any?)
    func toggleAutomaticUpdateChecks(_ sender: Any?)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, EditorMenuActions, NSMenuItemValidation {
    private var windowController: MainWindowController?
    private var updateChecker: UpdateChecker?
    /// URLs delivered by Launch Services before the window exists.
    private var pendingURLs: [URL] = []
    private var didFinishLaunching = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = RecentsController()   // becomes NSDocumentController.shared (first instance wins)
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MainWindowController()
        windowController = controller
        controller.showWindow(nil)
        didFinishLaunching = true
        if pendingURLs.isEmpty {
            controller.restoreLastSession()
        } else {
            pendingURLs.forEach { controller.open($0) }
            pendingURLs = []
        }
        ProbeLog.shared.start()
        ProbeLog.shared.dump()
        NSApp.activate()
        startUpdateChecker()
    }

    /// Off until the user says yes (one-time sheet on the second launch); see UpdateChecker.
    private func startUpdateChecker() {
        let checker = UpdateChecker(feedURL: UpdateChecker.resolveFeedURL(),
                                    currentVersion: UpdateChecker.bundleVersion())
        let alerts = UpdateAlerts(
            window: { [weak self] in self?.windowController?.window },
            openURL: { NSWorkspace.shared.open($0) },
            answer: { [weak checker] enabled in
                guard let checker else { return }
                Task { @MainActor in await checker.answerAutomaticQuestion(enabled) }
            })
        checker.present = { alerts.present($0) }
        updateChecker = checker
        guard !UserDefaults.standard.bool(forKey: UpdateChecker.disabledKey) else { return }
        Task { @MainActor in await checker.handleLaunch() }
    }

    /// Dock-icon drop, Finder "Open With", `open -a "Markdown Editor" <path>`, Open Recent.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard didFinishLaunching, let controller = windowController else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        for url in urls { controller.open(url) }
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    /// Quitting never drops edits silently: if the note can't be saved the user must choose.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        (windowController?.prepareToClose() ?? true) ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) { windowController?.save() }
    func applicationWillResignActive(_ notification: Notification) { windowController?.save() }

    // MARK: Menu actions

    /// File › New (⌘N): a new empty note — see `MainWindowController.newNote()`.
    @objc func newDocument(_ sender: Any?) { windowController?.newNote() }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.folder] + FolderTree.markdownExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        windowController?.open(url)
    }

    @objc func saveDocument(_ sender: Any?) { windowController?.save() }

    /// App menu › Check for Updates…: always fetches and always reports.
    @objc func checkForUpdates(_ sender: Any?) {
        guard let checker = updateChecker else { return }
        Task { @MainActor in await checker.checkNow() }
    }

    /// App menu › Check for Updates Automatically (a checkmark item).
    @objc func toggleAutomaticUpdateChecks(_ sender: Any?) {
        guard let checker = updateChecker else { return }
        let enabled = !checker.automaticChecksEnabled
        Task { @MainActor in await checker.answerAutomaticQuestion(enabled) }
    }

    /// Only the automatic-check item needs state; every other delegate action stays enabled.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleAutomaticUpdateChecks(_:)) {
            menuItem.state = updateChecker?.automaticChecksEnabled == true ? .on : .off
            return updateChecker != nil
        }
        if menuItem.action == #selector(checkForUpdates(_:)) { return updateChecker != nil }
        return true
    }

    func open(_ url: URL) { windowController?.open(url) }
}

/// Routes File › Open Recent to the main window (there are no NSDocument subclasses).
final class RecentsController: NSDocumentController {
    override func openDocument(withContentsOf url: URL, display displayDocument: Bool,
                               completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        (NSApp.delegate as? AppDelegate)?.open(url)
        completionHandler(nil, false, nil)
    }
}
