import XCTest
@testable import MarkdownCore

/// Test fixtures live under the package's .build directory, never /tmp.
func fixtureDirectory(_ name: String, file: StaticString = #filePath) throws -> URL {
    let root = URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/test-fixtures/\(name)-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

final class FolderTreeTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = try fixtureDirectory("tree")
        let fm = FileManager.default
        for f in ["a.md", "B.markdown", "c.txt", ".hidden.md", "sub/n.md"] {
            let url = dir.appendingPathComponent(f)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "x".write(to: url, atomically: true, encoding: .utf8)
        }
        for d in ["Sub 10", "Sub 2", ".git"] {
            try fm.createDirectory(at: dir.appendingPathComponent(d), withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testListsFoldersFirstThenMarkdownInFinderOrder() {
        let root = FileNode(url: dir, isDirectory: true)
        XCTAssertEqual(root.loadChildren().map(\.name), ["sub", "Sub 2", "Sub 10", "a.md", "B.markdown"])
        XCTAssertEqual(root.children?.first?.isDirectory, true)
    }

    func testChildrenAreLazy() {
        let root = FileNode(url: dir, isDirectory: true)
        XCTAssertFalse(root.isLoaded)
        let sub = root.loadChildren()[0]
        XCTAssertFalse(sub.isLoaded)
        XCTAssertEqual(sub.loadChildren().map(\.name), ["n.md"])
    }

    func testReloadKeepsExistingNodesAndPicksUpNewFiles() throws {
        let root = FileNode(url: dir, isDirectory: true)
        let sub = root.loadChildren()[0]
        try "y".write(to: dir.appendingPathComponent("new.md"), atomically: true, encoding: .utf8)
        root.reload()
        XCTAssertTrue(root.children!.contains { $0 === sub })
        XCTAssertTrue(root.children!.contains { $0.name == "new.md" })
    }

    func testNodeForURLWalksDown() {
        let root = FileNode(url: dir, isDirectory: true)
        XCTAssertEqual(root.node(for: dir.appendingPathComponent("sub/n.md"))?.name, "n.md")
        XCTAssertNil(root.node(for: dir.appendingPathComponent("c.txt")))
    }
}

final class OpenTargetTests: XCTestCase {
    func testResolve() throws {
        let dir = try fixtureDirectory("open")
        defer { try? FileManager.default.removeItem(at: dir) }
        let md = dir.appendingPathComponent("Note.MD")
        let txt = dir.appendingPathComponent("x.txt")
        try "a".write(to: md, atomically: true, encoding: .utf8)
        try "a".write(to: txt, atomically: true, encoding: .utf8)

        let folder = OpenTarget.resolve(dir)
        XCTAssertEqual(folder?.folder, dir.standardizedFileURL)
        XCTAssertNil(folder?.file)

        let file = OpenTarget.resolve(md)
        XCTAssertEqual(file?.folder, dir.standardizedFileURL)
        XCTAssertEqual(file?.file, md.standardizedFileURL)

        XCTAssertNil(OpenTarget.resolve(txt))
        XCTAssertNil(OpenTarget.resolve(dir.appendingPathComponent("missing.md")))
    }
}

final class FileStoreTests: XCTestCase {
    func testRoundTripAndPermissionsAndNoOpWrite() throws {
        let dir = try fixtureDirectory("store")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("note.md")
        let text = "# Héllo 👋🏽\n\n**bold**\n"
        XCTAssertTrue(try FileStore.write(text, to: url))
        XCTAssertEqual(try FileStore.read(url), text)

        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertTrue(try FileStore.write(text + "more\n", to: url))
        XCTAssertEqual(try FileStore.read(url), text + "more\n")
        let mode = try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)

        let past = Date(timeIntervalSinceNow: -3600)
        try fm.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
        XCTAssertFalse(try FileStore.write(text + "more\n", to: url))
        let mdate = try fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertEqual(mdate!.timeIntervalSince1970, past.timeIntervalSince1970, accuracy: 1)
    }
}
