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
}
