import AppKit
import XCTest
@testable import MarkdownCore
@testable import MarkdownEditor

@MainActor
final class FileSessionTests: XCTestCase {
    var dir: URL!
    var editor: EditorViewController!
    var session: FileSession!
    var failures: [Error] = []
    var discardAnswer = false
    var discardAsked = 0
    var closedExternally: [URL] = []

    override func setUp() async throws {
        dir = try fixtureDirectory("session")
        editor = EditorViewController()
        editor.loadView()
        session = FileSession(editor: editor)
        session.onSaveFailure = { [unowned self] error, _ in failures.append(error) }
        session.confirmDiscard = { [unowned self] _ in discardAsked += 1; return discardAnswer }
        session.onClosedExternally = { [unowned self] url in closedExternally.append(url) }
    }

    override func tearDown() async throws {
        session.close()
        if let dir {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
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

    func testSaveWritesAndClears() throws {
        let a = try file("a.md", "A\n")
        XCTAssertTrue(session.open(a))
        type("more")
        XCTAssertTrue(session.isDirty)
        XCTAssertTrue(session.save())
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "A\nmore")
    }

    func testFailedSaveKeepsBufferDirtyAndReports() throws {
        let a = try file("a.md", "A\n")
        XCTAssertTrue(session.open(a))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: a.path)
        type("important edit")
        XCTAssertFalse(session.save())
        XCTAssertTrue(session.isDirty)
        XCTAssertNotNil(session.lastSaveError)
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "A\n")
        XCTAssertTrue(editor.text.hasSuffix("important edit"))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: a.path)
        XCTAssertTrue(session.save())      // recovers once writable again
        XCTAssertNil(session.lastSaveError)
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "A\nimportant edit")
    }

    func testSwitchIsRefusedUntilSavedOrDiscarded() throws {
        let a = try file("a.md", "A\n")
        let b = try file("b.md", "B\n")
        XCTAssertTrue(session.open(a))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: a.path)
        type("important edit")

        discardAnswer = false
        XCTAssertFalse(session.open(b))
        XCTAssertEqual(discardAsked, 1)
        XCTAssertEqual(session.currentURL, a)
        XCTAssertTrue(editor.text.hasSuffix("important edit"))
        XCTAssertFalse(session.close())       // folder switch / quit refused too
        XCTAssertEqual(session.currentURL, a)

        discardAnswer = true
        XCTAssertTrue(session.open(b))
        XCTAssertEqual(session.currentURL, b)
        XCTAssertEqual(editor.text, "B\n")
    }

    func testNoDiscardHandlerMeansNeverDiscard() throws {
        session.confirmDiscard = nil
        let a = try file("a.md", "A\n")
        let b = try file("b.md", "B\n")
        XCTAssertTrue(session.open(a))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: a.path)
        type("x")
        XCTAssertFalse(session.open(b))
        XCTAssertEqual(session.currentURL, a)
    }

    func testSymlinkSavesThroughToTarget() throws {
        let target = try file("target.md", "T\n")
        let link = dir.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertTrue(session.open(link))
        type("via link")
        XCTAssertTrue(session.save())
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "T\nvia link")
        let type = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeSymbolicLink)
    }

    func testDeletedFileIsClosedNotRecreated() throws {
        let a = try file("a.md", "A\n")
        XCTAssertTrue(session.open(a))
        type("edit")
        try FileManager.default.removeItem(at: a)
        XCTAssertTrue(session.save())
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertNil(session.currentURL)
        XCTAssertEqual(closedExternally, [a])
    }

    func testNoSuchFileErrorWhileNoteExistsKeepsTheText() throws {
        let a = try file("a.md", "A\n")
        XCTAssertTrue(session.open(a))
        session.writer = { _, _, _, _ in throw CocoaError(.fileNoSuchFile) }
        type("keep me")
        XCTAssertFalse(session.save())
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(session.currentURL, a)
        XCTAssertEqual(closedExternally, [])
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(editor.text.hasSuffix("keep me"))
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "A\n")
    }

    func testCoordinatedDeletionClosesTheFile() throws {
        let a = try file("a.md", "A\n")
        XCTAssertTrue(session.open(a))
        let done = expectation(description: "deleted")
        // A coordinated delete asks the presenter (on the main queue) first, so run it off-main.
        DispatchQueue.global().async {
            var error: NSError?
            NSFileCoordinator().coordinate(writingItemAt: a, options: .forDeleting, error: &error) { url in
                try? FileManager.default.removeItem(at: url)
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        let deadline = Date(timeIntervalSinceNow: 2)
        while session.currentURL != nil, Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        XCTAssertNil(session.currentURL)
        XCTAssertEqual(closedExternally, [a])
    }

    func testMoveToTrashClosesAndRenameFollows() throws {
        let a = try file("a.md", "A\n")
        XCTAssertTrue(session.open(a))
        let renamed = dir.appendingPathComponent("renamed.md").standardizedFileURL
        session.handleMove(to: renamed)
        XCTAssertEqual(session.currentURL, renamed)
        XCTAssertEqual(editor.baseURL?.standardizedFileURL, dir.standardizedFileURL)
        session.handleMove(to: URL(fileURLWithPath: NSHomeDirectory() + "/.Trash/renamed.md"))
        XCTAssertNil(session.currentURL)
        XCTAssertEqual(closedExternally, [renamed])
    }

    func testExternalChangeReloadsCleanBufferOnlyWhenDateMoved() throws {
        let a = try file("a.md", "A\n")
        XCTAssertTrue(session.open(a))
        try "changed\n".write(to: a, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 10)], ofItemAtPath: a.path)
        session.reloadFromDisk()
        XCTAssertEqual(editor.text, "changed\n")

        // Same modification date: not re-read even though the bytes differ.
        let date = try FileManager.default.attributesOfItem(atPath: a.path)[.modificationDate] as! Date
        try "sneaky\n".write(to: a, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: a.path)
        session.reloadFromDisk()
        XCTAssertEqual(editor.text, "changed\n")

        // Dirty buffer keeps its text.
        type("mine")
        try "theirs\n".write(to: a, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 20)], ofItemAtPath: a.path)
        session.reloadFromDisk()
        XCTAssertEqual(editor.text, "changed\nmine")
    }

    func testEncodingIsPreserved() throws {
        let url = dir.appendingPathComponent("u16.md")
        try "# héllo\n".write(to: url, atomically: true, encoding: .utf16)
        XCTAssertTrue(session.open(url))
        XCTAssertEqual(editor.text, "# héllo\n")
        type("more")
        XCTAssertTrue(session.save())
        let data = try Data(contentsOf: url)
        XCTAssertTrue(data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), "still UTF-16 with BOM")
        XCTAssertEqual(String(data: data, encoding: .utf16), "# héllo\nmore")
    }
}

@MainActor
final class RestoreSessionTests: XCTestCase {
    var dir: URL!
    let defaults = UserDefaults.standard

    override func setUp() async throws {
        dir = try fixtureDirectory("restore")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "n\n".write(to: dir.appendingPathComponent("sub/n.md"), atomically: true, encoding: .utf8)
        try "top\n".write(to: dir.appendingPathComponent("top.md"), atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        defaults.removeObject(forKey: MainWindowController.lastFolderKey)
        defaults.removeObject(forKey: MainWindowController.lastFileKey)
        try? FileManager.default.removeItem(at: dir)
    }

    func testRelaunchRestoresRootFolderAndNestedFile() {
        let first = MainWindowController()
        first.open(dir)
        first.open(dir.appendingPathComponent("top.md"))       // file directly in root: stays rooted
        XCTAssertEqual(first.folder, dir.standardizedFileURL)
        // Select a nested note the way the sidebar does.
        first.sidebar.reveal(dir.appendingPathComponent("sub/n.md"))
        first.sidebar.onSelectFile?(dir.appendingPathComponent("sub/n.md").standardizedFileURL)
        XCTAssertEqual(first.folder, dir.standardizedFileURL)
        first.session.close()

        let second = MainWindowController()
        second.restoreLastSession()
        XCTAssertEqual(second.folder, dir.standardizedFileURL)
        XCTAssertEqual(second.session.currentURL, dir.appendingPathComponent("sub/n.md").standardizedFileURL)
        XCTAssertEqual(second.sidebar.selectedFile, dir.appendingPathComponent("sub/n.md").standardizedFileURL)
        second.session.close()
    }

    func testOpeningAFileInsideTheRootKeepsTheRoot() throws {
        let c = MainWindowController()
        c.open(dir)
        XCTAssertTrue(c.open(dir.appendingPathComponent("sub/n.md")))
        XCTAssertEqual(c.folder, dir.standardizedFileURL)
        XCTAssertEqual(c.session.currentURL, dir.appendingPathComponent("sub/n.md").standardizedFileURL)
        XCTAssertEqual(c.sidebar.selectedFile, dir.appendingPathComponent("sub/n.md").standardizedFileURL)

        // A file outside the root re-roots to its parent folder.
        let other = try fixtureDirectory("restore-outside")
        defer { try? FileManager.default.removeItem(at: other) }
        try "o\n".write(to: other.appendingPathComponent("o.md"), atomically: true, encoding: .utf8)
        XCTAssertTrue(c.open(other.appendingPathComponent("o.md")))
        XCTAssertEqual(c.folder, other.standardizedFileURL)
        XCTAssertEqual(c.session.currentURL, other.appendingPathComponent("o.md").standardizedFileURL)
        c.session.close()
    }

    func testFileOutsideRootIsNotRestored() throws {
        let other = try fixtureDirectory("restore-other")
        defer { try? FileManager.default.removeItem(at: other) }
        try "o\n".write(to: other.appendingPathComponent("o.md"), atomically: true, encoding: .utf8)
        defaults.set(dir.path, forKey: MainWindowController.lastFolderKey)
        defaults.set(other.appendingPathComponent("o.md").path, forKey: MainWindowController.lastFileKey)
        let c = MainWindowController()
        c.restoreLastSession()
        XCTAssertEqual(c.folder, dir.standardizedFileURL)
        XCTAssertNil(c.session.currentURL)
    }
}

@MainActor
final class NewNoteTests: XCTestCase {
    var dir: URL!
    let defaults = UserDefaults.standard

    override func setUp() async throws {
        dir = try fixtureDirectory("new-note")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "n\n".write(to: dir.appendingPathComponent("sub/n.md"), atomically: true, encoding: .utf8)
        try "top\n".write(to: dir.appendingPathComponent("top.md"), atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        defaults.removeObject(forKey: MainWindowController.lastFolderKey)
        defaults.removeObject(forKey: MainWindowController.lastFileKey)
        try? FileManager.default.removeItem(at: dir)
    }

    private func path(_ name: String) -> String { dir.appendingPathComponent(name).standardizedFileURL.path }

    func testRefreshRevealsAFileCreatedInALoadedFolder() throws {
        let sidebar = SidebarViewController()
        sidebar.loadView()
        sidebar.setRoot(dir)
        let late = dir.appendingPathComponent("late.md")
        try "x".write(to: late, atomically: true, encoding: .utf8)
        sidebar.reveal(late)
        XCTAssertNil(sidebar.selectedFile, "the root is loaded, so a new file is unknown until refreshed")
        sidebar.refresh(directory: dir)
        sidebar.reveal(late)
        XCTAssertEqual(sidebar.selectedFile?.path, path("late.md"))
        XCTAssertEqual(sidebar.selectedDirectory?.path, dir.standardizedFileURL.path)
    }

    func testNewNoteCreatesSelectsAndOpensThenNumbers() throws {
        let c = MainWindowController()
        c.open(dir)
        c.newNote()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("Untitled.md")))
        XCTAssertEqual(c.session.currentURL?.path, path("Untitled.md"))
        XCTAssertEqual(c.sidebar.selectedFile?.path, path("Untitled.md"))
        XCTAssertEqual(c.editor.text, "")
        c.newNote()
        XCTAssertEqual(c.session.currentURL?.path, path("Untitled 2.md"))
        XCTAssertEqual(c.sidebar.selectedFile?.path, path("Untitled 2.md"))
        c.session.close()
    }

    func testNewNoteGoesIntoTheSelectedFolderOrTheSelectedFilesFolder() throws {
        let c = MainWindowController()
        c.open(dir)
        let names = c.sidebar.visibleRowNames.map { $0.trimmingCharacters(in: .whitespaces) }
        c.sidebar.outlineView.selectRowIndexes([names.firstIndex(of: "sub")!], byExtendingSelection: false)
        XCTAssertEqual(c.sidebar.selectedDirectory?.path, path("sub"))
        c.newNote()
        XCTAssertEqual(c.session.currentURL?.path, path("sub/Untitled.md"))
        XCTAssertEqual(c.sidebar.selectedFile?.path, path("sub/Untitled.md"))
        // A selected file means its folder.
        c.newNote()
        XCTAssertEqual(c.session.currentURL?.path, path("sub/Untitled 2.md"))
        c.session.close()
    }

    func testNewNoteNeverTouchesAnExistingUntitled() throws {
        try "keep\n".write(to: dir.appendingPathComponent("Untitled.md"), atomically: true, encoding: .utf8)
        let c = MainWindowController()
        c.open(dir)
        c.newNote()
        XCTAssertEqual(c.session.currentURL?.path, path("Untitled 2.md"))
        XCTAssertEqual(try String(contentsOfFile: path("Untitled.md"), encoding: .utf8), "keep\n")
        c.session.close()
    }

    func testNewNoteStaysInsideTheRootWhenTheOpenNoteIsOutsideIt() throws {
        let outside = try fixtureDirectory("new-note-outside")
        defer { try? FileManager.default.removeItem(at: outside) }
        let moved = outside.appendingPathComponent("moved.md")
        try "m\n".write(to: moved, atomically: true, encoding: .utf8)
        let c = MainWindowController()
        c.open(dir)
        // The session follows a note moved out of the root (Finder); nothing is selected in the sidebar.
        XCTAssertTrue(c.session.open(moved))
        XCTAssertNil(c.sidebar.selectedDirectory)
        c.newNote()
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("Untitled.md").path))
        XCTAssertEqual(c.session.currentURL?.path, path("Untitled.md"))
        XCTAssertEqual(c.sidebar.selectedFile?.path, path("Untitled.md"))
        c.session.close()
    }

    func testIsInsideComparesWholePathComponents() {
        XCTAssertTrue(MainWindowController.isInside(dir, dir))
        XCTAssertTrue(MainWindowController.isInside(dir.appendingPathComponent("sub"), dir))
        XCTAssertFalse(MainWindowController.isInside(URL(fileURLWithPath: dir.path + "-sibling"), dir))
        XCTAssertFalse(MainWindowController.isInside(dir.deletingLastPathComponent(), dir))
    }

    func testRefusedSaveCreatesNoFile() throws {
        let c = MainWindowController()
        c.open(dir)
        c.open(dir.appendingPathComponent("top.md"))
        let top = dir.appendingPathComponent("top.md").standardizedFileURL
        XCTAssertEqual(c.session.currentURL, top)
        var asked = 0
        c.session.onSaveFailure = { _, _ in }
        c.session.confirmDiscard = { _ in asked += 1; return false }   // Keep Editing
        c.session.writer = { _, _, _, _ in throw CocoaError(.fileWriteNoPermission) }
        let tv = c.editor.textView!
        tv.insertText("unsaved", replacementRange: tv.selectedRange())
        XCTAssertTrue(c.session.isDirty)
        c.newNote()
        XCTAssertEqual(asked, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("Untitled.md")))
        XCTAssertEqual(c.session.currentURL, top)
        XCTAssertTrue(c.editor.text.contains("unsaved"))
        c.session.confirmDiscard = { _ in true }
        c.session.close()
    }
}
