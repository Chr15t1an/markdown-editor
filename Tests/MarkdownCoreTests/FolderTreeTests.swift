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

    func testListsImagesBesideMarkdown() throws {
        for f in ["photo.PNG", "shot.jpeg", "anim.gif", "vector.svg"] {
            try "x".write(to: dir.appendingPathComponent(f), atomically: true, encoding: .utf8)
        }
        let children = FileNode(url: dir, isDirectory: true).loadChildren()
        let names = children.map(\.name)
        for name in ["a.md", "B.markdown", "photo.PNG", "shot.jpeg", "anim.gif"] {
            XCTAssertTrue(names.contains(name), name)
        }
        XCTAssertFalse(names.contains("c.txt"))
        XCTAssertFalse(names.contains("vector.svg"), "SVG is not a listed image")
        XCTAssertEqual(Array(names.prefix(3)), ["sub", "Sub 2", "Sub 10"])
        XCTAssertEqual(children.first { $0.name == "photo.PNG" }?.isImage, true)
        XCTAssertEqual(children.first { $0.name == "a.md" }?.isImage, false)
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

    func testResolveImageOpensItsFolder() throws {
        let dir = try fixtureDirectory("open-image")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pic = dir.appendingPathComponent("Pic.JPG")
        let svg = dir.appendingPathComponent("v.svg")
        try "x".write(to: pic, atomically: true, encoding: .utf8)
        try "x".write(to: svg, atomically: true, encoding: .utf8)
        let target = OpenTarget.resolve(pic)
        XCTAssertEqual(target?.folder.path, dir.standardizedFileURL.path)
        XCTAssertEqual(target?.file?.path, pic.standardizedFileURL.path)
        XCTAssertNil(OpenTarget.resolve(svg))
        XCTAssertNil(OpenTarget.resolve(dir.appendingPathComponent("missing.png")))
    }

    func testRestorableFileAcceptsAnImage() throws {
        let dir = try fixtureDirectory("restorable")
        let other = try fixtureDirectory("restorable-other")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: other)
        }
        for f in ["pic.png", "n.md", "x.txt"] {
            try "x".write(to: dir.appendingPathComponent(f), atomically: true, encoding: .utf8)
        }
        try "x".write(to: other.appendingPathComponent("o.png"), atomically: true, encoding: .utf8)
        func restored(_ url: URL) -> String? { OpenTarget.restorableFile(url.path, in: dir)?.path }
        XCTAssertEqual(restored(dir.appendingPathComponent("pic.png")), dir.appendingPathComponent("pic.png").standardizedFileURL.path)
        XCTAssertEqual(restored(dir.appendingPathComponent("n.md")), dir.appendingPathComponent("n.md").standardizedFileURL.path)
        XCTAssertNil(restored(dir.appendingPathComponent("x.txt")))
        XCTAssertNil(restored(other.appendingPathComponent("o.png")), "outside the folder")
        XCTAssertNil(restored(dir.appendingPathComponent("gone.png")), "missing")
        XCTAssertNil(OpenTarget.restorableFile(nil, in: dir))
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

    func testUntitledNames() {
        XCTAssertEqual(FileStore.untitledName(1), "Untitled.md")
        XCTAssertEqual(FileStore.untitledName(2), "Untitled 2.md")
        XCTAssertEqual(FileStore.untitledName(10), "Untitled 10.md")
    }

    func testCreateNewPicksNextFreeName() throws {
        let dir = try fixtureDirectory("create")
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try FileStore.createNew(in: dir)
        XCTAssertEqual(first.lastPathComponent, "Untitled.md")
        XCTAssertEqual(try Data(contentsOf: first), Data())
        let second = try FileStore.createNew(in: dir)
        XCTAssertEqual(second.lastPathComponent, "Untitled 2.md")
    }

    func testCreateNewNeverOverwritesAnExistingNote() throws {
        let dir = try fixtureDirectory("create-keep")
        defer { try? FileManager.default.removeItem(at: dir) }
        let existing = dir.appendingPathComponent("Untitled.md")
        try "keep me\n".write(to: existing, atomically: true, encoding: .utf8)
        let made = try FileStore.createNew(in: dir)
        XCTAssertEqual(made.lastPathComponent, "Untitled 2.md")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep me\n")
        XCTAssertThrowsError(try FileStore.createExclusively(existing)) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteFileExists)
        }
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep me\n")
    }

    func testCreateNewFillsAGap() throws {
        let dir = try fixtureDirectory("create-gap")
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["Untitled.md", "Untitled 3.md"] {
            try "x".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(try FileStore.createNew(in: dir).lastPathComponent, "Untitled 2.md")
    }

    // The ⌘N deadlock had two independent guards (see `createNew`'s doc comment); each test below
    // removes the other guard's help, so losing either one alone fails here — by timeout, not a hang.

    func testCreateExclusivelyDoesNotWaitOnTheCallersOwnPresenter() throws {
        let dir = try fixtureDirectory("create-own-presenter")
        defer { try? FileManager.default.removeItem(at: dir) }
        let existing = dir.appendingPathComponent("Untitled.md").standardizedFileURL
        try "keep me\n".write(to: existing, atomically: true, encoding: .utf8)
        let presenter = BusyPresenter(existing)
        defer { presenter.release() }
        // Coordinating on the presented file itself, so only excluding the presenter avoids the wait.
        let result = runWithTimeout(releasing: presenter) { () -> Error? in
            do { try FileStore.createExclusively(existing, presenter: presenter); return nil } catch { return error }
        }
        guard let result else { return XCTFail("createExclusively waited on its own presenter") }
        XCTAssertEqual((result as? CocoaError)?.code, .fileWriteFileExists)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep me\n")
    }

    func testCreateNewSkipsExistingNamesWithoutCoordinatingOnThem() throws {
        let dir = try fixtureDirectory("create-skip-presented")
        defer { try? FileManager.default.removeItem(at: dir) }
        let existing = dir.appendingPathComponent("Untitled.md").standardizedFileURL
        try "keep me\n".write(to: existing, atomically: true, encoding: .utf8)
        let presenter = BusyPresenter(existing)
        defer { presenter.release() }
        // No presenter passed: only skipping the existing name avoids waiting on its presenter.
        let result = runWithTimeout(releasing: presenter) { try? FileStore.createNew(in: dir) }
        guard let made = result else { return XCTFail("createNew coordinated on an existing, presented note") }
        XCTAssertEqual(made?.lastPathComponent, "Untitled 2.md")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep me\n")
    }

    /// Runs `body` off the main thread; nil if it has not finished within `timeout`. A stuck
    /// coordination is then unblocked by releasing the presenter, so the thread still ends.
    private func runWithTimeout<T: Sendable>(releasing presenter: BusyPresenter, timeout: TimeInterval = 3,
                                             _ body: @escaping @Sendable () -> T) -> T? {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.value = body()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            presenter.release()
            _ = done.wait(timeout: .now() + timeout)
            return nil
        }
        return box.value
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    var value: T? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// A file presenter whose operation queue stays busy until `release()` — like the app's
/// `FileSession` (queue `.main`) while the main thread is blocked inside a coordination. Any
/// coordinated access that has to consult it waits until released.
private final class BusyPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var released = false

    init(_ url: URL) {
        presentedItemURL = url
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        presentedItemOperationQueue = queue
        super.init()
        let gate = gate
        queue.addOperation { gate.wait() }
        NSFileCoordinator.addFilePresenter(self)
    }

    // The same presenter methods the app's FileSession implements: a coordinated write consults
    // a presenter that implements them (one that implements none is never waited on).
    func presentedItemDidChange() {}
    func presentedItemDidMove(to newURL: URL) {}
    func accommodatePresentedItemDeletion(completionHandler: @escaping @Sendable (Error?) -> Void) { completionHandler(nil) }

    func release() {
        let first = lock.withLock { () -> Bool in
            defer { released = true }
            return !released
        }
        guard first else { return }
        gate.signal()
        NSFileCoordinator.removeFilePresenter(self)
    }
}
