// Runner entry point: runs the tests listed in registry.swift (generated) against the XCTest shim.
// Usage: <binary> [filter]   filter is a substring of "ClassName.testName" (e.g. "BlockScannerTests" or ".testHeadings").
import AppKit
import XCTest

@MainActor
enum TestRunner {
    static var filter: String?
    static var ran = 0
    static var failedTests: [String] = []
    static var perFile: [String: (ran: Int, failed: Int)] = [:]
    static var fileOrder: [String] = []

    static func run<T: XCTestCase>(_ type: T.Type, _ className: String, file: String,
                                   tests: [(String, @MainActor (T) async throws -> Void)]) async {
        for (name, body) in tests {
            let full = "\(className).\(name)"
            if let f = filter, !full.contains(f) { continue }
            if perFile[file] == nil { perFile[file] = (0, 0); fileOrder.append(file) }
            ran += 1
            perFile[file]!.ran += 1
            let before = XCTRecorder.shared.failureCount
            XCTRecorder.shared.begin(full)
            let start = Date()
            let t = T()
            do {
                try await t.setUp()
                try t.setUpWithError()
                let syncSetUp: () -> Void = t.setUp   // in an async context a bare t.setUp() resolves to the async overload
                syncSetUp()
                try await body(t)
            } catch {
                XCTRecorder.shared.record("threw error \"\(error)\"", file: #filePath, line: #line)
            }
            do {
                let syncTearDown: () -> Void = t.tearDown
                syncTearDown()
                try t.tearDownWithError()
                try await t.tearDown()
            } catch {
                XCTRecorder.shared.record("tearDown threw error \"\(error)\"", file: #filePath, line: #line)
            }
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let failures = XCTRecorder.shared.failureCount - before
            if failures > 0 {
                failedTests.append(full)
                perFile[file]!.failed += 1
                print("FAIL \(full) (\(failures) failure\(failures == 1 ? "" : "s"), \(ms) ms)")
            } else {
                print("PASS \(full) (\(ms) ms)")
            }
        }
    }

    static func summary() -> Int32 {
        print("")
        print("Per file:")
        for file in fileOrder {
            let r = perFile[file]!
            print("  \(file): \(r.ran) ran, \(r.ran - r.failed) passed, \(r.failed) failed")
        }
        print("")
        print("Executed \(ran) tests, \(failedTests.count) failed (\(XCTRecorder.shared.failureCount) assertion failures)")
        for f in failedTests { print("  FAILED: \(f)") }
        return failedTests.isEmpty ? 0 : 1
    }

    /// The sidebar autosaves expanded folders under "NSOutlineView Items Sidebar:<folder path>"
    /// (SidebarViewController.setRoot), and every fixture folder has a random suffix, so each run
    /// would add keys to ~/Library/Preferences/MarkdownCoreTests.plist forever. Drop every key that
    /// names a fixture folder that no longer exists. A folder still on disk may belong to a run in
    /// a sibling worktree that is mid-test, so live fixtures are left alone.
    static func pruneFixtureDefaults() {
        let marker = "/.build/test-fixtures/"
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        guard let keys = defaults.persistentDomain(forName: domain)?.keys else { return }
        var pruned = 0
        for key in keys {
            guard let hit = key.range(of: marker) else { continue }
            let start = key[..<hit.lowerBound].lastIndex(of: ":").map { key.index(after: $0) } ?? key.startIndex
            let name = key[hit.upperBound...].prefix { $0 != "/" }
            guard !name.isEmpty else { continue }
            let fixture = String(key[start..<hit.upperBound]) + name
            if !FileManager.default.fileExists(atPath: fixture) {
                defaults.removeObject(forKey: key)
                pruned += 1
            }
        }
        if pruned > 0 {
            defaults.synchronize()
            print("Pruned \(pruned) stale fixture preference key\(pruned == 1 ? "" : "s")")
        }
    }
}

@main
@MainActor
struct Main {
    static func main() async {
        // Headless AppKit: the editor tests build NSViews/NSTextViews; no window, no dock icon, no run loop.
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        TestRunner.filter = CommandLine.arguments.dropFirst().first
        await runRegisteredTests()
        TestRunner.pruneFixtureDefaults()
        exit(TestRunner.summary())
    }
}
