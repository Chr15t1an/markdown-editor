// Minimal XCTest replacement for machines with only the Command Line Tools (no XCTest.framework).
// Compiled as `-module-name XCTest` so the package's test sources build unchanged.
// Covers exactly the surface Tests/MarkdownCoreTests uses (run by scripts/test.sh).
@_exported import Foundation   // real XCTest re-exports Foundation; tests rely on NSRange/NSString without importing it

// MARK: - Failure bookkeeping

public final class XCTRecorder: @unchecked Sendable {
    public static let shared = XCTRecorder()
    private let lock = NSLock()
    private var _failures: [String] = []
    private var _currentTest = ""

    public var failures: [String] { lock.withLock { _failures } }
    public var failureCount: Int { lock.withLock { _failures.count } }

    public func begin(_ name: String) { lock.withLock { _currentTest = name } }
    public func record(_ message: String, file: StaticString, line: UInt) {
        let text = "\(file):\(line): error: \(lock.withLock { _currentTest }) : \(message)"
        lock.withLock { _failures.append(text) }
        FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
    }
    public func failuresSince(_ mark: Int) -> Int { failureCount - mark }
}

@inline(__always)
private func fail(_ message: String, _ userMessage: String, file: StaticString, line: UInt) {
    XCTRecorder.shared.record(userMessage.isEmpty ? message : "\(message) - \(userMessage)", file: file, line: line)
}

private func describeThrow(_ error: Error, file: StaticString, line: UInt) {
    XCTRecorder.shared.record("threw error \"\(error)\"", file: file, line: line)
}

// MARK: - Expectations

public final class XCTestExpectation: @unchecked Sendable {
    public let expectationDescription: String
    private let lock = NSLock()
    private var _fulfilled = false
    public var isFulfilled: Bool { lock.withLock { _fulfilled } }
    public init(description: String) { expectationDescription = description }
    public func fulfill() { lock.withLock { _fulfilled = true } }
}

// MARK: - XCTestCase

private func spinMainRunLoop(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
}

open class XCTestCase: NSObject {
    public required override init() { super.init() }

    open func setUp() {}
    open func tearDown() {}
    open func setUpWithError() throws {}
    open func tearDownWithError() throws {}
    open func setUp() async throws {}
    open func tearDown() async throws {}

    /// Real XCTest measures 10 iterations; here the block runs once so the test still exercises the code.
    public func measure(_ block: () -> Void) { block() }

    public func expectation(description: String) -> XCTestExpectation { XCTestExpectation(description: description) }

    /// Spins the main run loop until every expectation is fulfilled or the timeout passes.
    public func wait(for expectations: [XCTestExpectation], timeout: TimeInterval,
                     file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !expectations.allSatisfy(\.isFulfilled), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        let unmet = expectations.filter { !$0.isFulfilled }
        if !unmet.isEmpty {
            fail("Asynchronous wait failed: Exceeded timeout of \(timeout) seconds, with unfulfilled expectations: \(unmet.map(\.expectationDescription))", "", file: file, line: line)
        }
    }

    /// Real XCTest declares this @MainActor too (XCTestCase+Async overlay).
    @MainActor
    public func fulfillment(of expectations: [XCTestExpectation], timeout: TimeInterval,
                            file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !expectations.allSatisfy(\.isFulfilled), Date() < deadline {
            spinMainRunLoop(0.01)   // wrapper: RunLoop.run(until:) is marked unavailable in async contexts
            await Task.yield()
        }
        let unmet = expectations.filter { !$0.isFulfilled }
        if !unmet.isEmpty {
            fail("Asynchronous wait failed: Exceeded timeout of \(timeout) seconds, with unfulfilled expectations: \(unmet.map(\.expectationDescription))", "", file: file, line: line)
        }
    }
}

// MARK: - Assertions

public func XCTFail(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    fail("XCTFail", message, file: file, line: line)
}

public func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                         _ message: @autoclosure () -> String = "",
                                         file: StaticString = #filePath, line: UInt = #line) {
    do {
        let (x, y) = (try a(), try b())
        if x != y { fail("XCTAssertEqual failed: (\"\(x)\") is not equal to (\"\(y)\")", message(), file: file, line: line) }
    } catch { describeThrow(error, file: file, line: line) }
}

public func XCTAssertEqual<T: FloatingPoint>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                             accuracy: T, _ message: @autoclosure () -> String = "",
                                             file: StaticString = #filePath, line: UInt = #line) {
    do {
        let (x, y) = (try a(), try b())
        if abs(x - y) > accuracy { fail("XCTAssertEqual failed: (\"\(x)\") is not equal to (\"\(y)\") +/- (\"\(accuracy)\")", message(), file: file, line: line) }
    } catch { describeThrow(error, file: file, line: line) }
}

public func XCTAssertNotEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                            _ message: @autoclosure () -> String = "",
                                            file: StaticString = #filePath, line: UInt = #line) {
    do {
        let (x, y) = (try a(), try b())
        if x == y { fail("XCTAssertNotEqual failed: (\"\(x)\") is equal to (\"\(y)\")", message(), file: file, line: line) }
    } catch { describeThrow(error, file: file, line: line) }
}

public func XCTAssertTrue(_ e: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "",
                          file: StaticString = #filePath, line: UInt = #line) {
    do { if try !e() { fail("XCTAssertTrue failed", message(), file: file, line: line) } }
    catch { describeThrow(error, file: file, line: line) }
}

public func XCTAssertFalse(_ e: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "",
                           file: StaticString = #filePath, line: UInt = #line) {
    do { if try e() { fail("XCTAssertFalse failed", message(), file: file, line: line) } }
    catch { describeThrow(error, file: file, line: line) }
}

public func XCTAssert(_ e: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "",
                      file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(try e(), message(), file: file, line: line)
}

public func XCTAssertNil(_ e: @autoclosure () throws -> Any?, _ message: @autoclosure () -> String = "",
                         file: StaticString = #filePath, line: UInt = #line) {
    do { if let v = try e() { fail("XCTAssertNil failed: \"\(v)\"", message(), file: file, line: line) } }
    catch { describeThrow(error, file: file, line: line) }
}

public func XCTAssertNotNil(_ e: @autoclosure () throws -> Any?, _ message: @autoclosure () -> String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
    do { if try e() == nil { fail("XCTAssertNotNil failed", message(), file: file, line: line) } }
    catch { describeThrow(error, file: file, line: line) }
}

public func XCTAssertLessThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                             _ message: @autoclosure () -> String = "",
                                             file: StaticString = #filePath, line: UInt = #line) {
    do {
        let (x, y) = (try a(), try b())
        if !(x < y) { fail("XCTAssertLessThan failed: (\"\(x)\") is not less than (\"\(y)\")", message(), file: file, line: line) }
    } catch { describeThrow(error, file: file, line: line) }
}

public func XCTAssertGreaterThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                                _ message: @autoclosure () -> String = "",
                                                file: StaticString = #filePath, line: UInt = #line) {
    do {
        let (x, y) = (try a(), try b())
        if !(x > y) { fail("XCTAssertGreaterThan failed: (\"\(x)\") is not greater than (\"\(y)\")", message(), file: file, line: line) }
    } catch { describeThrow(error, file: file, line: line) }
}

public func XCTAssertThrowsError<T>(_ e: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "",
                                    file: StaticString = #filePath, line: UInt = #line,
                                    _ errorHandler: (Error) -> Void = { _ in }) {
    do { _ = try e(); fail("XCTAssertThrowsError failed: did not throw an error", message(), file: file, line: line) }
    catch { errorHandler(error) }
}

public func XCTAssertNoThrow<T>(_ e: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "",
                                file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try e() } catch { fail("XCTAssertNoThrow failed: threw error \"\(error)\"", message(), file: file, line: line) }
}

public struct XCTUnwrapError: Error { public let message: String }

public func XCTUnwrap<T>(_ e: @autoclosure () throws -> T?, _ message: @autoclosure () -> String = "",
                         file: StaticString = #filePath, line: UInt = #line) throws -> T {
    if let v = try e() { return v }
    fail("XCTUnwrap failed: expected non-nil value of type \"\(T.self)\"", message(), file: file, line: line)
    throw XCTUnwrapError(message: message())
}
