import XCTest
@testable import MarkdownCore

final class BlockScannerTests: XCTestCase {
    private func kinds(_ text: String) -> [BlockKind] { BlockScanner.scan(text).map(\.kind) }
    private func r(_ loc: Int, _ len: Int) -> NSRange { NSRange(location: loc, length: len) }

    func testHeadings() {
        let blocks = BlockScanner.scan("# One\n###### Six\n####### seven\n#hashtag\n#\n")
        XCTAssertEqual(blocks.map(\.kind), [.heading(level: 1), .heading(level: 6), .paragraph, .paragraph, .heading(level: 1)])
        XCTAssertEqual(blocks[0].markerRanges, [r(0, 2)])
        XCTAssertEqual(blocks[0].contentRange, r(2, 3))
        XCTAssertEqual(blocks[0].range, r(0, 6))
    }

    func testHorizontalRuleVersusBullet() {
        XCTAssertEqual(kinds("---\n- item\n* * *\n___\n-- \n"),
                       [.horizontalRule, .bulletItem(depth: 0), .horizontalRule, .horizontalRule, .paragraph])
    }

    func testListsAndDepth() {
        let text = "- a\n  - b\n    * c\n\t+ d\n1. one\n10) ten\n-no\n"
        XCTAssertEqual(kinds(text), [.bulletItem(depth: 0), .bulletItem(depth: 1), .bulletItem(depth: 2),
                                     .bulletItem(depth: 2), .orderedItem(depth: 0), .orderedItem(depth: 0), .paragraph])
        let blocks = BlockScanner.scan(text)
        XCTAssertEqual(blocks[1].markerRanges, [r(4, 4)])   // "  - "
        XCTAssertEqual(blocks[4].markerRanges[0].length, 3) // "1. "
    }

    func testTasks() {
        let blocks = BlockScanner.scan("- [ ] todo\n- [x] done\n- [X] Done\n- [y] no\n")
        XCTAssertEqual(blocks.map(\.kind), [.taskItem(depth: 0, checked: false), .taskItem(depth: 0, checked: true),
                                            .taskItem(depth: 0, checked: true), .bulletItem(depth: 0)])
        XCTAssertEqual(blocks[0].markerRanges, [r(0, 6)])
        XCTAssertEqual(blocks[0].contentRange, r(6, 4))
    }

    func testBlockquote() {
        let blocks = BlockScanner.scan("> quote\n>tight\n> > nested\n")
        XCTAssertEqual(blocks.map(\.kind), [.blockquote, .blockquote, .blockquote])
        XCTAssertEqual(blocks[0].markerRanges, [r(0, 2)])
        XCTAssertEqual(blocks[1].markerRanges, [r(8, 1)])
        XCTAssertEqual(blocks[2].contentRange.length, "> nested".utf16.count)
    }

    func testFencedCode() {
        let text = "a\n```swift\nlet x = 1\n# not heading\n```\nb\n"
        let blocks = BlockScanner.scan(text)
        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .fencedCode(language: "swift"), .paragraph])
        let ns = text as NSString
        XCTAssertEqual(blocks[1].range, NSRange(location: 2, length: ns.length - 2 - 2))
        XCTAssertEqual(blocks[1].markerRanges, [ns.range(of: "```swift"), NSRange(location: ns.range(of: "```\nb").location, length: 3)])
        XCTAssertEqual(ns.substring(with: blocks[1].contentRange), "let x = 1\n# not heading\n")
    }

    func testTildeFenceAndMismatchedClose() {
        XCTAssertEqual(kinds("~~~~\n```\n~~~\n~~~~\nafter\n"), [.fencedCode(language: nil), .paragraph])
    }

    func testUnclosedFenceRunsToEnd() {
        let text = "```\ncode\n# still code\n"
        let blocks = BlockScanner.scan(text)
        XCTAssertEqual(blocks.map(\.kind), [.fencedCode(language: nil)])
        XCTAssertEqual(blocks[0].range, NSRange(location: 0, length: (text as NSString).length))
        XCTAssertEqual(blocks[0].markerRanges.count, 1)
    }

    func testFenceInsideList() {
        XCTAssertEqual(kinds("- item\n  ```\n  - code\n  ```\n- next\n"),
                       [.bulletItem(depth: 0), .fencedCode(language: nil), .bulletItem(depth: 0)])
    }

    func testBlankLines() {
        XCTAssertEqual(kinds("a\n\n   \nb"), [.paragraph, .blank, .blank, .paragraph])
    }

    func testCRLF() {
        let blocks = BlockScanner.scan("# H\r\n- a\r\n")
        XCTAssertEqual(blocks.map(\.kind), [.heading(level: 1), .bulletItem(depth: 0)])
        XCTAssertEqual(blocks[0].range, r(0, 5))
        XCTAssertEqual(blocks[0].contentRange, r(2, 1))
        XCTAssertEqual(blocks[1].range, r(5, 5))
    }

    func testDocumentBlockLookup() {
        let doc = MarkdownDocument("ab\ncd\n")
        XCTAssertEqual(doc.blockIndex(containing: 0), 0)
        XCTAssertEqual(doc.blockIndex(containing: 2), 0)
        XCTAssertEqual(doc.blockIndex(containing: 3), 1)
        XCTAssertNil(doc.blockIndex(containing: 6))
        XCTAssertEqual(MarkdownDocument("ab").blockIndex(containing: 2), 0)
    }
}
