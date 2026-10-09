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
        exit(TestRunner.summary())
    }
}
