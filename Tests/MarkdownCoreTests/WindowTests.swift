import AppKit
import XCTest
@testable import MarkdownCore
@testable import MarkdownEditor

/// Several windows: the registry's routing, the one-note-one-window guard, save-all on quit.
@MainActor
final class WindowTests: XCTestCase {
    var dir: URL!
    var other: URL!
    var registry: WindowRegistry!
    var focused: [MainWindowController] = []
    var alerts: [String] = []
    let defaults = UserDefaults.standard

    override func setUp() async throws {
        dir = try fixtureDirectory("windows")
        other = try fixtureDirectory("windows-other")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "n\n".write(to: dir.appendingPathComponent("n.md"), atomically: true, encoding: .utf8)
        try "s\n".write(to: dir.appendingPathComponent("sub/s.md"), atomically: true, encoding: .utf8)
        try "o\n".write(to: other.appendingPathComponent("o.md"), atomically: true, encoding: .utf8)
        focused = []
        alerts = []
        registry = WindowRegistry()
        registry.show = { _ in }
        registry.focus = { [unowned self] in focused.append($0) }
    }

    override func tearDown() async throws {
        for c in registry?.controllers ?? [] { c.session.close() }
        registry = nil
        defaults.removeObject(forKey: MainWindowController.lastFolderKey)
        defaults.removeObject(forKey: MainWindowController.lastFileKey)
        defaults.removeObject(forKey: DefaultFolder.key)
        if let dir { try? FileManager.default.removeItem(at: dir) }
        if let other { try? FileManager.default.removeItem(at: other) }
    }

    private func url(_ name: String) -> URL { dir.appendingPathComponent(name).standardizedFileURL }

    private func window() -> MainWindowController {
        let c = registry.makeWindow()
        c.presentAlert = { [unowned self] alert in alerts.append(alert.messageText + " | " + alert.informativeText) }
        return c
    }

    private func insert(_ text: String, in c: MainWindowController) {
        let tv = c.editor.textView!
        tv.setSelectedRange(NSRange(location: (c.editor.text as NSString).length, length: 0))
        tv.insertText(text, replacementRange: tv.selectedRange())
    }

    private func read(_ u: URL) throws -> String { try String(contentsOf: u, encoding: .utf8) }

    // MARK: Phase 1 — routing through the registry

    func testRegistryTargetsTheOnlyWindow() {
        XCTAssertNil(registry.target)
        let c = window()
        XCTAssertTrue(registry.target === c)
        XCTAssertTrue(c.registry === registry)
        XCTAssertEqual(registry.controllers.count, 1)
    }

    func testExternalOpenOfAFileInsideAWindowsRootGoesToThatWindow() {
        let a = window()
        a.open(dir)
        let b = window()
        b.open(other)
        XCTAssertTrue(registry.target === b)
        registry.open(url("sub/s.md"))
        XCTAssertEqual(a.session.currentURL?.path, url("sub/s.md").path)
        XCTAssertNil(b.session.currentURL)
        XCTAssertEqual(b.folder?.path, other.standardizedFileURL.path)
        XCTAssertTrue(focused.last === a)
        // A folder that is a window's root goes to that window too.
        registry.open(dir)
        XCTAssertTrue(focused.last === a)
        XCTAssertEqual(b.folder?.path, other.standardizedFileURL.path)
    }

    func testExternalOpenOutsideEveryRootUsesTheTargetWindow() throws {
        let a = window()
        a.open(dir)
        let elsewhere = try fixtureDirectory("windows-elsewhere")
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        try "e\n".write(to: elsewhere.appendingPathComponent("e.md"), atomically: true, encoding: .utf8)
        registry.open(elsewhere.appendingPathComponent("e.md"))
        XCTAssertEqual(a.folder?.path, elsewhere.standardizedFileURL.path)
        XCTAssertEqual(a.session.currentURL?.path, elsewhere.appendingPathComponent("e.md").standardizedFileURL.path)
        XCTAssertEqual(registry.controllers.count, 1)
        XCTAssertTrue(focused.last === a)
    }

    func testPrepareAllToCloseSavesEveryWindow() throws {
        let a = window()
        a.open(dir)
        a.open(url("n.md"))
        insert("alpha", in: a)
        let b = window()
        b.open(other)
        b.open(other.appendingPathComponent("o.md"))
        insert("beta", in: b)
        XCTAssertTrue(a.session.isDirty)
        XCTAssertTrue(b.session.isDirty)
        XCTAssertTrue(registry.prepareAllToClose())
        XCTAssertEqual(try read(url("n.md")), "n\nalpha")
        XCTAssertEqual(try read(other.appendingPathComponent("o.md")), "o\nbeta")
    }

    func testPrepareAllToCloseStopsAtTheFirstKeepEditing() throws {
        let a = window()
        a.open(dir)
        a.open(url("n.md"))
        insert("alpha", in: a)
        a.session.writer = { _, _, _, _ in throw CocoaError(.fileWriteNoPermission) }
        a.session.onSaveFailure = { _, _ in }
        a.session.confirmDiscard = { _ in false }   // Keep Editing
        let b = window()
        b.open(other)
        b.open(other.appendingPathComponent("o.md"))
        insert("beta", in: b)
        registry.didBecomeKey(a)   // a is the front window: asked first
        XCTAssertFalse(registry.prepareAllToClose())
        XCTAssertTrue(a.session.isDirty)
        XCTAssertTrue(b.session.isDirty, "the walk stopped before window 2")
        a.session.writer = { text, url, encoding, presenter in
            try FileStore.write(text, to: url, encoding: encoding, createIfMissing: false, presenter: presenter)
        }
    }

    func testNewSaveOpenAreAnsweredByTheWindow() throws {
        let c = window()
        c.open(dir)
        XCTAssertTrue(c.tryToPerform(#selector(WindowFileActions.newDocument(_:)), with: nil))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url("Untitled.md").path))
        XCTAssertEqual(c.session.currentURL?.path, url("Untitled.md").path)
        insert("x", in: c)
        XCTAssertTrue(c.tryToPerform(#selector(WindowFileActions.saveDocument(_:)), with: nil))
        XCTAssertEqual(try read(url("Untitled.md")), "x")
        XCTAssertTrue(c.responds(to: #selector(WindowFileActions.openDocument(_:))))
        let items = MainMenu.fileMenu().items
        XCTAssertEqual(items.first { $0.title == "New" }?.action, #selector(WindowFileActions.newDocument(_:)))
        XCTAssertEqual(items.first { $0.title == "Open…" }?.action, #selector(WindowFileActions.openDocument(_:)))
        XCTAssertEqual(items.first { $0.title == "Save" }?.action, #selector(WindowFileActions.saveDocument(_:)))
    }

    // MARK: Phase 2 — New Window, frames, one note in one window

    func testFileMenuHasNewWindowWithShiftCommandN() throws {
        let items = MainMenu.fileMenu().items
        let new = try XCTUnwrap(items.firstIndex { $0.title == "New" })
        let item = items[new + 1]
        XCTAssertEqual(item.title, "New Window")
        XCTAssertEqual(item.action, #selector(EditorMenuActions.newWindow(_:)))
        XCTAssertEqual(item.keyEquivalent, "n")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertTrue(AppDelegate().responds(to: #selector(EditorMenuActions.newWindow(_:))))
    }

    func testNewWindowAddsASecondWindowWithoutTheFrameAutosave() {
        let a = window()
        let b = registry.newWindow()
        XCTAssertEqual(registry.controllers.count, 2)
        XCTAssertTrue(registry.controllers[1] === b)
        XCTAssertEqual(a.window?.frameAutosaveName, "MainWindow")
        XCTAssertEqual(b.window?.frameAutosaveName, "")
        XCTAssertTrue(a.autosavesFrame)
        XCTAssertFalse(b.autosavesFrame)
        XCTAssertEqual(a.splitViewController.splitView.autosaveName, "MainSplit")
        XCTAssertNotEqual(b.splitViewController.splitView.autosaveName, "MainSplit")
    }

    func testANoteOpenInAnotherWindowFocusesItInstead() {
        let a = window()
        a.open(dir)
        a.open(url("n.md"))
        let b = window()
        b.open(dir)
        focused = []
        b.sidebar.onSelectFile?(url("n.md"))
        XCTAssertNil(b.session.currentURL)
        XCTAssertEqual(focused.count, 1)
        XCTAssertTrue(focused.first === a)
        XCTAssertEqual(a.session.currentURL?.path, url("n.md").path)
    }

    func testOpenRoutesAFileOpenElsewhereToItsWindow() {
        let a = window()
        a.open(dir)
        a.open(url("n.md"))
        let b = window()
        b.open(other)
        XCTAssertTrue(registry.target === b)
        focused = []
        registry.open(url("n.md"))
        XCTAssertTrue(focused.last === a)
        XCTAssertNil(b.session.currentURL)
        XCTAssertEqual(b.folder?.path, other.standardizedFileURL.path)
    }

    func testRestoreDoesNotOpenANoteHeldByAnotherWindow() {
        let a = window()
        a.open(dir)
        a.open(url("n.md"))
        defaults.set(dir.path, forKey: MainWindowController.lastFolderKey)
        defaults.set(url("n.md").path, forKey: MainWindowController.lastFileKey)
        let b = window()
        b.restoreLastSession()
        XCTAssertEqual(b.folder?.path, dir.standardizedFileURL.path)
        XCTAssertNil(b.session.currentURL)
        XCTAssertEqual(a.session.currentURL?.path, url("n.md").path)
    }

    func testSaveAsOntoANoteOpenInAnotherWindowIsRefused() throws {
        let a = window()
        a.open(dir)
        a.open(url("n.md"))
        let b = window()
        b.open(other)
        b.open(other.appendingPathComponent("o.md"))
        insert("b-text", in: b)
        XCTAssertFalse(b.saveAs(to: url("n.md")))
        XCTAssertEqual(alerts, ["Couldn’t save “n.md” | “n.md” is open in another window."])
        XCTAssertEqual(try read(url("n.md")), "n\n")
        XCTAssertEqual(b.session.currentURL?.path, other.appendingPathComponent("o.md").standardizedFileURL.path)
    }

    func testSaveAsOntoACaseVariantOfANoteOpenElsewhereIsRefused() throws {
        let variant = dir.appendingPathComponent("N.md")
        guard FileManager.default.fileExists(atPath: variant.path) else { return }   // case-sensitive volume
        let a = window()
        a.open(dir)
        a.open(url("n.md"))
        let b = window()
        b.open(other)
        b.open(other.appendingPathComponent("o.md"))
        XCTAssertFalse(b.saveAs(to: variant))
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(try read(url("n.md")), "n\n")
    }

    func testMoveOntoANoteOpenElsewhereIsRefused() throws {
        let a = window()
        a.open(dir)
        a.open(url("n.md"))
        try "other n\n".write(to: other.appendingPathComponent("n.md"), atomically: true, encoding: .utf8)
        let b = window()
        b.open(other)
        b.open(other.appendingPathComponent("n.md"))
        XCTAssertFalse(b.moveOpenFile(to: dir))
        XCTAssertEqual(alerts, ["Couldn’t move “n.md” | “n.md” is open in another window. Nothing was moved."])
        XCTAssertEqual(try read(url("n.md")), "n\n")
        XCTAssertEqual(try read(other.appendingPathComponent("n.md")), "other n\n")
    }

    func testSameFileMatchesSymlinkAndCaseVariant() throws {
        let n = url("n.md")
        let link = dir.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: n)
        XCTAssertTrue(WindowRegistry.sameFile(n, link))
        XCTAssertTrue(WindowRegistry.sameFile(n, dir.appendingPathComponent("sub/../n.md")))
        let hard = dir.appendingPathComponent("hard.md")
        try FileManager.default.linkItem(at: n, to: hard)
        XCTAssertTrue(WindowRegistry.sameFile(n, hard))
        XCTAssertFalse(WindowRegistry.sameFile(n, url("sub/s.md")))
        // Neither exists: compared by path, case-folded.
        XCTAssertTrue(WindowRegistry.sameFile(dir.appendingPathComponent("gone.md"), dir.appendingPathComponent("GONE.md")))
        XCTAssertFalse(WindowRegistry.sameFile(dir.appendingPathComponent("gone.md"), dir.appendingPathComponent("gone2.md")))
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("N.md").path) {
            XCTAssertTrue(WindowRegistry.sameFile(n, dir.appendingPathComponent("N.md")))
        }
    }

    func testDropOfANoteOpenElsewhereLeavesThisWindowsFolder() {
        let a = window()
        a.open(dir)
        a.open(url("n.md"))
        let b = window()
        b.open(other)
        focused = []
        XCTAssertFalse(b.open(url("n.md")))
        XCTAssertEqual(b.folder?.path, other.standardizedFileURL.path)
        XCTAssertNil(b.session.currentURL)
        XCTAssertTrue(focused.last === a)
    }

    func testClosingAWindowUnregistersItsNote() async throws {
        let a = window()
        a.open(dir)
        a.open(url("n.md"))
        XCTAssertTrue(NSFileCoordinator.filePresenters.contains { $0 === a.session })
        let b = window()
        b.open(other)
        a.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        // The registry drops the window on a later main-queue turn: let it run (≤ 2 s).
        let deadline = Date().addingTimeInterval(2)
        while registry.controllers.contains(where: { $0 === a }), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(NSFileCoordinator.filePresenters.contains { $0 === a.session })
        XCTAssertFalse(registry.controllers.contains { $0 === a })
        XCTAssertTrue(b.open(url("n.md")))
        XCTAssertEqual(b.session.currentURL?.path, url("n.md").path)
        insert("after-close", in: b)
        let start = Date()
        XCTAssertTrue(b.save())
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(try read(url("n.md")), "n\nafter-close")
    }

    func testTheGuardNeverRegistersASecondPresenter() throws {
        let a = window()
        a.open(dir)
        a.open(url("n.md"))
        insert("dirty", in: a)
        let b = window()
        b.open(dir)
        b.sidebar.onSelectFile?(url("n.md"))
        b.open(url("n.md"))
        registry.open(url("n.md"), from: b)
        b.restoreLastSession()
        XCTAssertNil(b.session.currentURL)
        try "x\n".write(to: url("x.md"), atomically: true, encoding: .utf8)
        b.open(url("x.md"))
        XCTAssertFalse(b.saveAs(to: url("n.md")))
        XCTAssertEqual(b.session.currentURL?.path, url("x.md").path)
        XCTAssertEqual(NSFileCoordinator.filePresenters.filter {
            ($0 as? FileSession)?.currentURL.map { WindowRegistry.sameFile($0, self.url("n.md")) } ?? false
        }.count, 1)
        let start = Date()
        XCTAssertTrue(a.save())
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(try read(url("n.md")), "n\ndirty")
    }

    // MARK: Phase 3 — the default notes folder

    private func useAsDefaultItem() throws -> NSMenuItem {
        try XCTUnwrap(MainMenu.fileMenu().items.first { $0.title == "Use as Default Folder" })
    }

    func testUseAsDefaultFolderSetsAndClearsTheKey() throws {
        let items = MainMenu.fileMenu().items
        let recent = try XCTUnwrap(items.firstIndex { $0.title == "Open Recent" })
        XCTAssertEqual(items[recent + 1].title, "Use as Default Folder")
        let item = try useAsDefaultItem()
        XCTAssertEqual(item.action, #selector(DocumentFileActions.toggleDefaultFolder(_:)))
        let c = window()
        XCTAssertFalse(c.validateMenuItem(item), "disabled with no folder open")
        c.open(dir)
        XCTAssertTrue(c.validateMenuItem(item))
        XCTAssertEqual(item.state, .off)
        c.toggleDefaultFolder(item)
        XCTAssertEqual(defaults.string(forKey: DefaultFolder.key), dir.standardizedFileURL.path)
        XCTAssertTrue(c.validateMenuItem(item))
        XCTAssertEqual(item.state, .on)
        c.toggleDefaultFolder(item)
        XCTAssertNil(defaults.string(forKey: DefaultFolder.key))
        XCTAssertTrue(c.validateMenuItem(item))
        XCTAssertEqual(item.state, .off)
    }

    func testNewWindowOpensTheDefaultFolder() {
        defaults.set(dir.path, forKey: DefaultFolder.key)
        defaults.set(url("n.md").path, forKey: MainWindowController.lastFileKey)
        let a = window()
        a.open(other)
        let b = registry.newWindow()
        XCTAssertEqual(b.folder?.path, dir.standardizedFileURL.path)
        XCTAssertNil(b.session.currentURL)
        XCTAssertNil(b.sidebar.selectedFile)
        XCTAssertEqual(a.folder?.path, other.standardizedFileURL.path)
    }

    func testNewWindowWithNoOrAMissingDefaultShowsTheEmptyState() {
        let a = registry.newWindow()
        XCTAssertNil(a.folder)
        defaults.set(dir.appendingPathComponent("gone").path, forKey: DefaultFolder.key)
        let b = registry.newWindow()
        XCTAssertNil(b.folder)
        XCTAssertNil(DefaultFolder.url())
        XCTAssertNotNil(defaults.string(forKey: DefaultFolder.key), "the key stays (an unmounted volume may come back)")
        defaults.set(url("n.md").path, forKey: DefaultFolder.key)   // a file is not a folder
        XCTAssertNil(DefaultFolder.url())
    }

    func testPlainLaunchOpensTheDefaultFolderNotTheLastFolder() {
        defaults.set(other.path, forKey: MainWindowController.lastFolderKey)
        defaults.set(dir.path, forKey: DefaultFolder.key)
        registry.launch(pending: [])
        XCTAssertEqual(registry.controllers.count, 1)
        XCTAssertEqual(registry.controllers[0].folder?.path, dir.standardizedFileURL.path)
    }

    func testPlainLaunchRestoresTheLastFileOnlyInsideTheDefault() {
        defaults.set(dir.path, forKey: DefaultFolder.key)
        defaults.set(url("sub/s.md").path, forKey: MainWindowController.lastFileKey)
        registry.launch(pending: [])
        let c = registry.controllers[0]
        XCTAssertEqual(c.session.currentURL?.path, url("sub/s.md").path)
        c.session.close()

        let second = WindowRegistry()
        second.show = { _ in }
        defaults.set(other.appendingPathComponent("o.md").path, forKey: MainWindowController.lastFileKey)
        second.launch(pending: [])
        XCTAssertEqual(second.controllers[0].folder?.path, dir.standardizedFileURL.path)
        XCTAssertNil(second.controllers[0].session.currentURL)
    }

    func testPlainLaunchWithAMissingDefaultFallsBackToTheLastFolder() {
        defaults.set(dir.appendingPathComponent("gone").path, forKey: DefaultFolder.key)
        defaults.set(other.path, forKey: MainWindowController.lastFolderKey)
        registry.launch(pending: [])
        XCTAssertEqual(registry.controllers[0].folder?.path, other.standardizedFileURL.path)
    }

    func testLaunchWithAFileIgnoresTheDefault() {
        defaults.set(dir.path, forKey: DefaultFolder.key)
        registry.launch(pending: [other.appendingPathComponent("o.md")])
        XCTAssertEqual(registry.controllers.count, 1)
        let c = registry.controllers[0]
        XCTAssertEqual(c.folder?.path, other.standardizedFileURL.path)
        XCTAssertEqual(c.session.currentURL?.path, other.appendingPathComponent("o.md").standardizedFileURL.path)
    }

    func testNewNoteInTheNewWindowGoesIntoTheDefaultFolderAndLeavesWindowOneAlone() throws {
        defaults.set(dir.path, forKey: DefaultFolder.key)
        let a = window()
        a.open(other.appendingPathComponent("o.md"))
        let b = registry.newWindow()
        XCTAssertTrue(b.tryToPerform(#selector(WindowFileActions.newDocument(_:)), with: nil))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url("Untitled.md").path))
        XCTAssertEqual(b.session.currentURL?.path, url("Untitled.md").path)
        XCTAssertEqual(a.folder?.path, other.standardizedFileURL.path)
        XCTAssertEqual(a.session.currentURL?.path, other.appendingPathComponent("o.md").standardizedFileURL.path)
        XCTAssertEqual(try read(other.appendingPathComponent("o.md")), "o\n")
    }
}
