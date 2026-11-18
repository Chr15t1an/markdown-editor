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
