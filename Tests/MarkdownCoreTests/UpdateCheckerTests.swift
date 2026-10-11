import XCTest
@testable import MarkdownCore
@testable import MarkdownEditor

/// Counts fetches across the @Sendable boundary (a captured `var` can't be mutated there).
final class FetchStub: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private let result: Result<Data, Error>

    init(_ result: Result<Data, Error>) { self.result = result }

    var calls: Int { lock.withLock { _calls } }

    var fetch: UpdateChecker.Fetch {
        { [self] _ in
            lock.withLock { _calls += 1 }
            return try result.get()
        }
    }

    static func feed(_ version: String) -> FetchStub {
        FetchStub(.success(Data(#"{"version":"\#(version)","url":"https://markdown.chri5tian.com/"}"#.utf8)))
    }
}

struct StubError: LocalizedError {
    var errorDescription: String? { "offline" }
}

@MainActor
final class UpdateCheckerTests: XCTestCase {
    let suite = "UpdateCheckerTests"
    var defaults: UserDefaults!
    var shown: [UpdateChecker.Presentation] = []
    let feedURL = URL(string: "https://markdown.chri5tian.com/version.json")!

    override func setUp() async throws {
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
        shown = []
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func makeChecker(_ stub: FetchStub, current: String = "0.3.2") -> UpdateChecker {
        let checker = UpdateChecker(feedURL: feedURL, currentVersion: current, defaults: defaults, fetch: stub.fetch)
        checker.present = { [unowned self] in shown.append($0); return true }
        return checker
    }

    func testAutomaticChecksAreOffUntilAnswered() async {
        let stub = FetchStub.feed("9.9.9")
        let checker = makeChecker(stub)
        XCTAssertFalse(checker.automaticChecksEnabled)
        XCTAssertFalse(checker.hasAnsweredAutomaticQuestion)
        let outcome = await checker.checkIfDue()
        XCTAssertEqual(outcome, .skipped)
        XCTAssertEqual(stub.calls, 0, "auto disabled: fetch never called")
    }

    func testFirstLaunchIsSilentSecondLaunchAsksOnce() async {
        let stub = FetchStub.feed("9.9.9")
        let checker = makeChecker(stub)
        let first = await checker.handleLaunch()
        XCTAssertEqual(first, .skipped)
        XCTAssertEqual(shown, [])
        let second = await checker.handleLaunch()
        XCTAssertEqual(second, .asked)
        XCTAssertEqual(shown, [.askToEnable])
        XCTAssertEqual(stub.calls, 0, "asking sends nothing")

        let declined = await checker.answerAutomaticQuestion(false)
        XCTAssertEqual(declined, .skipped)
        let third = await checker.handleLaunch()
        XCTAssertEqual(third, .skipped)
        XCTAssertEqual(shown, [.askToEnable], "asked once only")
        XCTAssertEqual(stub.calls, 0)
    }

    func testAnsweringYesChecksAndShowsNewerVersion() async {
        let stub = FetchStub.feed("9.9.9")
        let checker = makeChecker(stub)
        let outcome = await checker.answerAutomaticQuestion(true)
        let feed = UpdateFeed(version: "9.9.9", url: URL(string: "https://markdown.chri5tian.com/")!)
        XCTAssertEqual(outcome, .available(feed))
        XCTAssertEqual(shown, [.available(feed, current: "0.3.2")])
        XCTAssertTrue(checker.automaticChecksEnabled)
        XCTAssertNotNil(defaults.object(forKey: UpdateChecker.lastCheckKey) as? Date, "lastUpdateCheck written on success")
    }

    func testAutomaticCheckRunsAtMostOncePerDay() async {
        let stub = FetchStub.feed("0.3.2")
        let checker = makeChecker(stub)
        var clock = Date(timeIntervalSince1970: 2_000_000)
        checker.now = { clock }
        checker.automaticChecksEnabled = true
        let first = await checker.checkIfDue()
        XCTAssertEqual(first, .upToDate)
        XCTAssertEqual(shown, [], "auto: up to date is silent")
        clock = clock.addingTimeInterval(23 * 3600)
        let early = await checker.checkIfDue()
        XCTAssertEqual(early, .skipped)
        XCTAssertEqual(stub.calls, 1)
        clock = clock.addingTimeInterval(2 * 3600)
        _ = await checker.checkIfDue()
        XCTAssertEqual(stub.calls, 2)
    }

    func testAutomaticShowsEachVersionOnce() async {
        let stub = FetchStub.feed("9.9.9")
        let checker = makeChecker(stub)
        var clock = Date(timeIntervalSince1970: 3_000_000)
        checker.now = { clock }
        checker.automaticChecksEnabled = true
        _ = await checker.checkIfDue()
        clock = clock.addingTimeInterval(25 * 3600)
        let again = await checker.checkIfDue()
        XCTAssertEqual(again, .skipped)
        XCTAssertEqual(shown.count, 1, "no daily re-nag for the same version")
        XCTAssertEqual(defaults.string(forKey: UpdateChecker.lastNotifiedKey), "9.9.9")

        _ = await checker.checkNow()
        XCTAssertEqual(shown.count, 2, "manual always shows")
    }

    func testAutomaticFailureIsSilentManualFailureAlerts() async {
        let stub = FetchStub(.failure(StubError()))
        let checker = makeChecker(stub)
        checker.automaticChecksEnabled = true
        let auto = await checker.checkIfDue()
        XCTAssertEqual(auto, .failed("offline"))
        XCTAssertEqual(shown, [])
        XCTAssertNil(defaults.object(forKey: UpdateChecker.lastCheckKey), "a failed check is retried next launch")
        let manual = await checker.checkNow()
        XCTAssertEqual(manual, .failed("offline"))
        XCTAssertEqual(shown, [.failed(message: "offline")])
    }

    func testManualUpToDateAlerts() async {
        let stub = FetchStub.feed("0.3.2")
        let checker = makeChecker(stub)
        let outcome = await checker.checkNow()
        XCTAssertEqual(outcome, .upToDate)
        XCTAssertEqual(shown, [.upToDate(current: "0.3.2")])
        XCTAssertFalse(checker.automaticChecksEnabled, "a manual check doesn't turn on automatic checks")
    }

    func testManualWithMalformedFeedFails() async {
        let stub = FetchStub(.success(Data("<html>not json</html>".utf8)))
        let checker = makeChecker(stub)
        let outcome = await checker.checkNow()
        guard case .failed = outcome else { return XCTFail("expected .failed, got \(outcome)") }
        XCTAssertEqual(shown.count, 1)
    }

    func testNoFeedURLFailsWithoutFetching() async {
        let stub = FetchStub.feed("9.9.9")
        let checker = UpdateChecker(feedURL: nil, currentVersion: "0.3.2", defaults: defaults, fetch: stub.fetch)
        checker.present = { [unowned self] in shown.append($0); return true }
        let outcome = await checker.checkNow()
        guard case .failed = outcome else { return XCTFail("expected .failed, got \(outcome)") }
        XCTAssertEqual(stub.calls, 0)
    }

    func testFeedURLOverrideComesFromArgumentsAndIsRestricted() {
        let local = UpdateChecker.resolveFeedURL(bundle: Bundle(for: UpdateCheckerTests.self),
                                                 arguments: [UpdateChecker.feedURLKey: "http://127.0.0.1:8765/version.json"])
        XCTAssertEqual(local, URL(string: "http://127.0.0.1:8765/version.json"))
        let rejected = UpdateChecker.resolveFeedURL(bundle: Bundle(for: UpdateCheckerTests.self),
                                                    arguments: [UpdateChecker.feedURLKey: "http://evil.example/version.json"])
        XCTAssertNil(rejected, "the test bundle has no MEUpdateFeedURL, and plain http is refused")
    }
}
