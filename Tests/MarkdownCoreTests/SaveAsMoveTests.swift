import AppKit
import XCTest
@testable import MarkdownCore
@testable import MarkdownEditor

final class FileStoreMoveTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = try fixtureDirectory("move")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "A\n".write(to: dir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testMoveRenamesIntoTheFolder() throws {
        let a = dir.appendingPathComponent("a.md")
        let target = dir.appendingPathComponent("sub/a.md")
        try FileStore.move(a, to: target)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "A\n")
    }

    func testMoveRefusesATakenNameAndChangesNothing() throws {
        let a = dir.appendingPathComponent("a.md")
        let target = dir.appendingPathComponent("sub/a.md")
        try "other\n".write(to: target, atomically: true, encoding: .utf8)
        var refused = false
        do {
            try FileStore.move(a, to: target)
        } catch CocoaError.fileWriteFileExists {
            refused = true
        }
        XCTAssertTrue(refused)
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "A\n")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "other\n")
    }
}

@MainActor
final class SaveAsSessionTests: XCTestCase {
    var dir: URL!
    var editor: EditorViewController!
    var session: FileSession!

    override func setUp() async throws {
        dir = try fixtureDirectory("save-as")
        editor = EditorViewController()
        editor.loadView()
        session = FileSession(editor: editor)
        session.onSaveFailure = { _, _ in }
        session.confirmDiscard = { _ in true }
    }

    override func tearDown() async throws {
        session.close()
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func file(_ name: String, _ text: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.standardizedFileURL
    }

    private func type(_ text: String) {
        let tv = editor.textView!
        tv.setSelectedRange(NSRange(location: (editor.text as NSString).length, length: 0))
        tv.insertText(text, replacementRange: tv.selectedRange())
    }

    func testSaveAsWritesTheBufferAndContinuesOnTheNewFile() throws {
        let a = try file("a.md", "A\n")
        XCTAssertTrue(session.open(a))
        type("new")
        XCTAssertTrue(session.isDirty)
        let b = dir.appendingPathComponent("b.md")
        try session.saveAs(to: b)
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "A\nnew")
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "A\n")
        XCTAssertEqual(session.currentURL?.path, b.standardizedFileURL.path)
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(editor.baseURL?.standardizedFileURL.path, dir.standardizedFileURL.path)
        type("more")
        XCTAssertTrue(session.save())
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "A\nnewmore")
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "A\n")
    }

    func testSaveAsKeepsTheNoteEncoding() throws {
        let url = dir.appendingPathComponent("u16.md")
        try "# héllo\n".write(to: url, atomically: true, encoding: .utf16)
        XCTAssertTrue(session.open(url))
        type("x")
        let copy = dir.appendingPathComponent("copy.md")
        try session.saveAs(to: copy)
        let data = try Data(contentsOf: copy)
        XCTAssertTrue(data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), "still UTF-16 with BOM")
        XCTAssertEqual(String(data: data, encoding: .utf16), editor.text)
        XCTAssertEqual(editor.text, "# héllo\nx")
    }

    func testSaveAsRecoversFromAFailingSave() throws {
        let a = try file("a.md", "A\n")
        XCTAssertTrue(session.open(a))
        var recovered = 0
        session.onSaveRecovered = { recovered += 1 }
        session.writer = { _, _, _, _ in throw CocoaError(.fileWriteNoPermission) }
        type("keep")
        XCTAssertFalse(session.save())
        XCTAssertNotNil(session.lastSaveError)
        let rescued = dir.appendingPathComponent("rescued.md")
        try session.saveAs(to: rescued)
        XCTAssertTrue(try String(contentsOf: rescued, encoding: .utf8).hasSuffix("keep"))
        XCTAssertNil(session.lastSaveError)
        XCTAssertEqual(recovered, 1)
        XCTAssertEqual(session.currentURL?.path, rescued.standardizedFileURL.path)
    }

    func testSaveAsToTheSameFileJustSaves() throws {
        let a = try file("a.md", "A\n")
        XCTAssertTrue(session.open(a))
        type("z")
        try session.saveAs(to: a)
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "A\nz")
        XCTAssertEqual(session.currentURL?.path, a.path)
        XCTAssertFalse(session.isDirty)
    }
}

@MainActor
final class SaveAsAndMoveToTests: XCTestCase {
    var dir: URL!
    var alerts: [String] = []
    let defaults = UserDefaults.standard

    override func setUp() async throws {
        dir = try fixtureDirectory("save-as-move")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "n\n".write(to: dir.appendingPathComponent("sub/n.md"), atomically: true, encoding: .utf8)
        try "top\n".write(to: dir.appendingPathComponent("top.md"), atomically: true, encoding: .utf8)
        alerts = []
    }

    override func tearDown() async throws {
        defaults.removeObject(forKey: MainWindowController.lastFolderKey)
        defaults.removeObject(forKey: MainWindowController.lastFileKey)
        try? FileManager.default.removeItem(at: dir)
    }

    private func path(_ name: String) -> String { dir.appendingPathComponent(name).standardizedFileURL.path }
    private func url(_ name: String) -> URL { dir.appendingPathComponent(name) }
    private func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: path(name)) }
    private func read(_ name: String) throws -> String { try String(contentsOfFile: path(name), encoding: .utf8) }

    private func controller() -> MainWindowController {
        let c = MainWindowController()
        c.presentAlert = { [unowned self] alert in alerts.append(alert.messageText) }
        return c
    }

    private func insert(_ text: String, in c: MainWindowController) {
        let tv = c.editor.textView!
        tv.setSelectedRange(NSRange(location: (c.editor.text as NSString).length, length: 0))
        tv.insertText(text, replacementRange: tv.selectedRange())
    }

    private func fileMenuItem(_ title: String) -> NSMenuItem? {
        MainMenu.fileMenu().items.first { $0.title == title }
    }

    func testFileMenuHasSaveAsAndMoveTo() throws {
        let menu = MainMenu.fileMenu()
        let titles = menu.items.map(\.title)
        let save = try XCTUnwrap(titles.firstIndex(of: "Save"))
        XCTAssertEqual(titles.firstIndex(of: "Save As…"), save + 1)
        XCTAssertEqual(titles.firstIndex(of: "Move To…"), save + 2)
        let saveAs = menu.items[save + 1], moveTo = menu.items[save + 2]
        XCTAssertEqual(saveAs.action, #selector(DocumentFileActions.saveDocumentAs(_:)))
        XCTAssertEqual(saveAs.keyEquivalent, "s")
        XCTAssertEqual(saveAs.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(moveTo.action, #selector(DocumentFileActions.moveDocument(_:)))
        XCTAssertEqual(moveTo.keyEquivalent, "")
        let c = controller()
        XCTAssertTrue(c.responds(to: #selector(DocumentFileActions.saveDocumentAs(_:))))
        XCTAssertTrue(c.responds(to: #selector(DocumentFileActions.moveDocument(_:))))
    }

    func testSaveAsAndMoveToAreDisabledWithNoNoteOpen() throws {
        let saveAs = try XCTUnwrap(fileMenuItem("Save As…"))
        let moveTo = try XCTUnwrap(fileMenuItem("Move To…"))
        let c = controller()
        XCTAssertFalse(c.validateMenuItem(saveAs))
        XCTAssertFalse(c.validateMenuItem(moveTo))
        c.open(dir)
        XCTAssertFalse(c.validateMenuItem(saveAs))
        XCTAssertFalse(c.validateMenuItem(moveTo))
        c.open(url("top.md"))
        XCTAssertTrue(c.validateMenuItem(saveAs))
        XCTAssertTrue(c.validateMenuItem(moveTo))
        try writeTestImage(url("p.png"), width: 4, height: 4)
        c.sidebar.refresh(directory: dir)
        XCTAssertTrue(c.open(url("p.png")))
        XCTAssertNotNil(c.viewedImage)
        XCTAssertFalse(c.validateMenuItem(saveAs))
        XCTAssertTrue(c.validateMenuItem(moveTo))
        c.session.close()
    }

    func testSaveAsSelectsTheNewFileAndLaterEditsSaveThere() throws {
        let c = controller()
        c.open(dir)
        c.open(url("top.md"))
        insert("unsaved", in: c)
        XCTAssertTrue(c.session.isDirty)
        XCTAssertTrue(c.saveAs(to: url("sub/copy.md")))
        XCTAssertEqual(try read("sub/copy.md"), c.editor.text)
        XCTAssertEqual(c.editor.text, "top\nunsaved")
        XCTAssertEqual(try read("top.md"), "top\n")
        XCTAssertEqual(c.session.currentURL?.path, path("sub/copy.md"))
        XCTAssertEqual(c.sidebar.selectedFile?.path, path("sub/copy.md"))
        XCTAssertEqual(c.folder?.path, dir.standardizedFileURL.path)
        XCTAssertEqual(c.window?.subtitle, "copy.md")
        XCTAssertEqual(defaults.string(forKey: MainWindowController.lastFileKey), path("sub/copy.md"))
        insert("more", in: c)
        XCTAssertTrue(c.save())
        XCTAssertEqual(try read("sub/copy.md"), "top\nunsavedmore")
        XCTAssertEqual(try read("top.md"), "top\n")
        XCTAssertEqual(alerts, [])
        c.session.close()
    }

    func testSaveAsOutsideTheRootOpensItsFolder() throws {
        let other = try fixtureDirectory("save-as-outside")
        defer { try? FileManager.default.removeItem(at: other) }
        let c = controller()
        c.open(dir)
        c.open(url("top.md"))
        c.editor.textView.setSelectedRange(NSRange(location: 2, length: 0))
        let target = other.appendingPathComponent("top.md")
        XCTAssertTrue(c.saveAs(to: target))
        XCTAssertEqual(c.folder?.path, other.standardizedFileURL.path)
        XCTAssertEqual(c.session.currentURL?.path, target.standardizedFileURL.path)
        XCTAssertEqual(c.sidebar.selectedFile?.path, target.standardizedFileURL.path)
        XCTAssertEqual(c.editor.textView.selectedRange().location, 2)
        XCTAssertTrue(exists("top.md"))
        c.session.close()
    }

    func testMoveToMovesTheNoteAndTheEditorFollows() throws {
        let c = controller()
        c.open(dir)
        c.open(url("top.md"))
        insert("x", in: c)
        XCTAssertTrue(c.moveOpenFile(to: url("sub")))
        XCTAssertFalse(exists("top.md"))
        XCTAssertEqual(try read("sub/top.md"), c.editor.text)
        XCTAssertEqual(c.session.currentURL?.path, path("sub/top.md"))
        XCTAssertEqual(c.sidebar.selectedFile?.path, path("sub/top.md"))
        XCTAssertEqual(defaults.string(forKey: MainWindowController.lastFileKey), path("sub/top.md"))
        insert("y", in: c)
        XCTAssertTrue(c.save())
        XCTAssertTrue(try read("sub/top.md").contains("y"))
        XCTAssertFalse(exists("top.md"))
        XCTAssertEqual(alerts, [])
        c.session.close()
    }

    func testMoveToRefusesATakenNameAndReportsIt() throws {
        try "other\n".write(to: url("sub/top.md"), atomically: true, encoding: .utf8)
        let c = controller()
        c.open(dir)
        c.open(url("top.md"))
        XCTAssertFalse(c.moveOpenFile(to: url("sub")))
        XCTAssertEqual(try read("top.md"), "top\n")
        XCTAssertEqual(try read("sub/top.md"), "other\n")
        XCTAssertEqual(c.session.currentURL?.path, path("top.md"))
        XCTAssertEqual(alerts, ["Couldn’t move “top.md”"])
        c.session.close()
    }

    func testMoveToOutsideTheRootKeepsTheNoteOpen() throws {
        let other = try fixtureDirectory("move-outside")
        defer { try? FileManager.default.removeItem(at: other) }
        let c = controller()
        c.open(dir)
        c.open(url("top.md"))
        XCTAssertTrue(c.moveOpenFile(to: other))
        let moved = other.appendingPathComponent("top.md").standardizedFileURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertFalse(exists("top.md"))
        XCTAssertEqual(c.session.currentURL?.path, moved.path)
        XCTAssertEqual(c.folder?.path, dir.standardizedFileURL.path)
        XCTAssertNil(c.sidebar.selectedFile)
        XCTAssertFalse(c.sidebar.visibleRowNames.map { $0.trimmingCharacters(in: .whitespaces) }.contains("top.md"))
        c.session.close()
    }

    func testMoveToItsOwnFolderDoesNothing() throws {
        let c = controller()
        c.open(dir)
        c.open(url("sub/n.md"))
        XCTAssertTrue(c.moveOpenFile(to: url("sub")))
        XCTAssertTrue(exists("sub/n.md"))
        XCTAssertEqual(c.session.currentURL?.path, path("sub/n.md"))
        XCTAssertEqual(alerts, [])
        c.session.close()
    }

    func testMoveToMovesTheImageOnScreen() throws {
        try writeTestImage(url("p.png"), width: 4, height: 4)
        let c = controller()
        c.open(dir)
        XCTAssertTrue(c.open(url("p.png")))
        XCTAssertTrue(c.moveOpenFile(to: url("sub")))
        XCTAssertTrue(exists("sub/p.png"))
        XCTAssertFalse(exists("p.png"))
        XCTAssertEqual(c.viewedImage?.path, path("sub/p.png"))
        XCTAssertEqual(c.sidebar.selectedFile?.path, path("sub/p.png"))
        XCTAssertEqual(alerts, [])
    }

    func testMenuActionsUseTheChosenLocationAndCancelChangesNothing() throws {
        let c = controller()
        c.open(dir)
        c.open(url("top.md"))
        let before = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        c.chooseSaveAsURL = { _ in nil }
        c.saveDocumentAs(nil)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), before)
        XCTAssertEqual(c.session.currentURL?.path, path("top.md"))
        c.chooseMoveDestination = { _ in nil }
        c.moveDocument(nil)
        XCTAssertEqual(c.session.currentURL?.path, path("top.md"))
        XCTAssertTrue(exists("top.md"))
        let sub = url("sub")
        c.chooseMoveDestination = { _ in sub }
        c.moveDocument(nil)
        XCTAssertEqual(c.session.currentURL?.path, path("sub/top.md"))
        var offered: String?
        let saved = url("saved.md")
        c.chooseSaveAsURL = { cur in offered = cur.path; return saved }
        c.saveDocumentAs(nil)
        XCTAssertEqual(offered, path("sub/top.md"))
        XCTAssertEqual(c.session.currentURL?.path, path("saved.md"))
        XCTAssertEqual(alerts, [])
        c.session.close()
    }
}
