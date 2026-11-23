import AppKit
import MarkdownCore

/// App-level menu actions with no AppKit declaration, so `#selector` can name them.
@MainActor @objc protocol EditorMenuActions {
    func checkForUpdates(_ sender: Any?)
    func toggleAutomaticUpdateChecks(_ sender: Any?)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, EditorMenuActions, WindowFileActions, NSMenuItemValidation {
    let windows = WindowRegistry()
    private var updateChecker: UpdateChecker?
    /// URLs delivered by Launch Services before the window exists.
    private var pendingURLs: [URL] = []
    private var didFinishLaunching = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = RecentsController()   // becomes NSDocumentController.shared (first instance wins)
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = windows.makeWindow()
        didFinishLaunching = true
        if pendingURLs.isEmpty {
            controller.restoreLastSession()
        } else {
            pendingURLs.forEach { windows.open($0, from: controller) }
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
        var alerts = UpdateAlerts(
            window: { [weak self] in self?.windows.target?.window },
            openURL: { NSWorkspace.shared.open($0) },
            answer: { [weak checker] enabled in
                guard let checker else { return }
                Task { @MainActor in await checker.answerAutomaticQuestion(enabled) }
            })
        alerts.installable = { [weak checker] feed in
            guard UpdateInstaller().locationProblem() == nil else { return nil }
            return checker?.package(for: feed)
        }
        alerts.install = { [weak self] package in self?.installUpdate(package) }
        let presentAlerts = alerts
        checker.present = { presentAlerts.present($0) }
        updateChecker = checker
        guard !UserDefaults.standard.bool(forKey: UpdateChecker.disabledKey) else { return }
        Task { @MainActor in await checker.handleLaunch() }
    }

    /// Install and Relaunch: download + verify + stage, save the note, swap, quit; the helper reopens.
    /// Any failure leaves the installed copy untouched and offers Download instead.
    private func installUpdate(_ package: UpdatePackage) {
        Task { @MainActor in
            let installer = UpdateInstaller()
            do {
                let staged = try await installer.prepare(package)
                guard windows.prepareAllToClose() else { installer.discard(staged); return }
                try installer.installAndScheduleRelaunch(staged)
                NSApp.terminate(nil)
            } catch {
                _ = updateChecker?.present(.installFailed(message: error.localizedDescription))
            }
        }
    }

    /// Dock-icon drop, Finder "Open With", `open -a "Markdown Editor" <path>`, Open Recent.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard didFinishLaunching else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        for url in urls { windows.open(url) }   // the registry brings the chosen window forward
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    /// Quitting never drops edits silently: if a note can't be saved the user must choose, per window.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        windows.prepareAllToClose() ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) { windows.saveAll() }
    func applicationWillResignActive(_ notification: Notification) { windows.saveAll() }

    // MARK: Menu actions

    // New / Open… / Save normally reach the key window's MainWindowController; these answer only
    // when no window is key (an inactive, probe-launched app) and act on the target window.
    @objc func newDocument(_ sender: Any?) { (windows.target ?? windows.makeWindow()).newNote() }

    @objc func openDocument(_ sender: Any?) {
        guard let url = MainWindowController.runOpenPanel() else { return }
        windows.open(url)
    }

    @objc func saveDocument(_ sender: Any?) { windows.target?.save() }

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

    func open(_ url: URL) { windows.open(url) }
}

/// Routes File › Open Recent to the main window (there are no NSDocument subclasses).
final class RecentsController: NSDocumentController {
    override func openDocument(withContentsOf url: URL, display displayDocument: Bool,
                               completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        (NSApp.delegate as? AppDelegate)?.open(url)
        completionHandler(nil, false, nil)
    }
}
