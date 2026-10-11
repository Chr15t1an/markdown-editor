import XCTest
@testable import MarkdownCore

final class UpdateCheckTests: XCTestCase {
    func testParseValidFeed() throws {
        let data = Data(#"{"version":"0.3.2","url":"https://markdown.chri5tian.com/"}"#.utf8)
        let feed = try UpdateCheck.parse(data)
        XCTAssertEqual(feed, UpdateFeed(version: "0.3.2", url: URL(string: "https://markdown.chri5tian.com/")!))
    }

    func testParseRejectsBadJSON() {
        XCTAssertThrowsError(try UpdateCheck.parse(Data("<html>404</html>".utf8)))
        XCTAssertThrowsError(try UpdateCheck.parse(Data(#"{"version":"0.3.2"}"#.utf8)))
        XCTAssertThrowsError(try UpdateCheck.parse(Data()))
    }

    func testIsNewer() {
        let table: [(String, String, Bool)] = [
            ("0.3.2", "0.3.1", true),
            ("0.3.1", "0.3.1", false),
            ("0.3.0", "0.3.1", false),
            ("0.10.0", "0.9.9", true),
            ("1.0.0", "0.99.99", true),
            ("1.0", "1.0.0", false),
            ("1.0.0", "1.0", false),
            ("1.0.1", "1.0", true),
            ("garbage", "0.3.1", false),
            ("v0.4.0", "0.3.1", false),
            ("", "0.3.1", false),
            ("0.4.0", "garbage", false),
            ("0.4.0-beta", "0.3.1", false),
            ("0..4", "0.3.1", false),
            ("99999999999999999999999.0", "0.3.1", false),
        ]
        for (candidate, current, expected) in table {
            XCTAssertEqual(UpdateCheck.isNewer(candidate, than: current), expected, "\(candidate) vs \(current)")
        }
    }

    func testIsDue() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(UpdateCheck.isDue(last: nil, now: now))
        XCTAssertFalse(UpdateCheck.isDue(last: now.addingTimeInterval(-23 * 3600), now: now))
        XCTAssertTrue(UpdateCheck.isDue(last: now.addingTimeInterval(-25 * 3600), now: now))
        XCTAssertTrue(UpdateCheck.isDue(last: now.addingTimeInterval(3600), now: now), "a future date never blocks checks")
    }

    func testDownloadURLOnlyFollowsTheSite() {
        let site = URL(string: "https://markdown.chri5tian.com/")!
        func url(_ s: String) -> URL { UpdateCheck.downloadURL(for: UpdateFeed(version: "1.0.0", url: URL(string: s)!)) }
        XCTAssertEqual(url("https://markdown.chri5tian.com/notes"), URL(string: "https://markdown.chri5tian.com/notes")!)
        XCTAssertEqual(url("http://markdown.chri5tian.com/"), site)
        XCTAssertEqual(url("https://evil.example/"), site)
        XCTAssertEqual(url("https://markdown.chri5tian.com.evil.example/"), site)
        XCTAssertEqual(url("https://markdown.chri5tian.com:8443/"), site)
        XCTAssertEqual(url("file:///Applications/"), site)
    }

    func testAllowedFeedURLs() {
        func allowed(_ s: String) -> Bool { UpdateCheck.isAllowedFeedURL(URL(string: s)!) }
        XCTAssertTrue(allowed("https://markdown.chri5tian.com/version.json"))
        XCTAssertTrue(allowed("http://127.0.0.1:8765/version.json"))
        XCTAssertFalse(allowed("http://127.0.0.1/version.json"))
        XCTAssertFalse(allowed("http://localhost:8765/version.json"))
        XCTAssertFalse(allowed("http://markdown.chri5tian.com/version.json"))
        XCTAssertFalse(allowed("file:///tmp/version.json"))
    }
}
