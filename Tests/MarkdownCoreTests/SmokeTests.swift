import XCTest
@testable import MarkdownCore

final class SmokeTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(MarkdownCore.version, "0.4.0")
    }
}
