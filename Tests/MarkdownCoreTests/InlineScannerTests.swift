import XCTest
@testable import MarkdownCore

final class InlineScannerTests: XCTestCase {
    private func r(_ loc: Int, _ len: Int) -> NSRange { NSRange(location: loc, length: len) }

    func testStrongEmphasisStrike() {
        let inl = InlineScanner.scan("a **b** *c* _d_ ~~e~~")
        XCTAssertEqual(inl.map(\.kind), [.strong, .emphasis, .emphasis, .strikethrough])
        XCTAssertEqual(inl[0].markerRanges, [r(2, 2), r(5, 2)])
        XCTAssertEqual(inl[0].contentRange, r(4, 1))
        XCTAssertEqual(inl[3].markerRanges, [r(16, 2), r(19, 2)])
    }

    func testNestedStrongAndEmphasis() {
        let inl = InlineScanner.scan("***x***")
        XCTAssertEqual(inl.count, 1)
        XCTAssertEqual(inl[0].kind, .emphasis)          // CommonMark: <em><strong>x</strong></em>
        XCTAssertEqual(inl[0].children.map(\.kind), [.strong])
        XCTAssertEqual(inl[0].children[0].contentRange, r(3, 1))

        let mixed = InlineScanner.scan("**bold *it* more**")
        XCTAssertEqual(mixed.map(\.kind), [.strong])
        XCTAssertEqual(mixed[0].children.map(\.kind), [.emphasis])
    }

    func testUnclosedStaysLiteral() {
        XCTAssertEqual(InlineScanner.scan("**open and * spaced *").map(\.kind), [])
        XCTAssertEqual(InlineScanner.scan("a ** b").count, 0)
        XCTAssertEqual(InlineScanner.scan("~one~").count, 0)
    }

    func testUnderscoreIntraword() {
        XCTAssertEqual(InlineScanner.scan("snake_case_name").count, 0)
        XCTAssertEqual(InlineScanner.scan("in*tra*word").map(\.kind), [.emphasis])
    }

    func testCodeSpanHidesInnerMarkers() {
        let inl = InlineScanner.scan("`a *b* c` and ``x ` y``")
        XCTAssertEqual(inl.map(\.kind), [.code, .code])
        XCTAssertEqual(inl[0].markerRanges, [r(0, 1), r(8, 1)])
        XCTAssertEqual(inl[0].children, [])
        XCTAssertEqual(inl[1].contentRange, r(16, 5))
        XCTAssertEqual(InlineScanner.scan("`unclosed *em*").map(\.kind), [.emphasis])
    }

    func testLink() {
        let text = "see [the **docs**](https://x.io/a_(b)) now"
        let inl = InlineScanner.scan(text)
        XCTAssertEqual(inl.map(\.kind), [.link(url: "https://x.io/a_(b)")])
        let ns = text as NSString
        XCTAssertEqual(inl[0].markerRanges, [r(4, 1), NSRange(location: ns.range(of: "](").location, length: ns.range(of: ") now").location + 1 - ns.range(of: "](").location)])
        XCTAssertEqual(ns.substring(with: inl[0].contentRange), "the **docs**")
        XCTAssertEqual(inl[0].children.map(\.kind), [.strong])
    }

    func testLinkWithNestedBracketsAndTitle() {
        let inl = InlineScanner.scan("[a [b] c](<my url> \"T\")")
        XCTAssertEqual(inl.map(\.kind), [.link(url: "my url")])
        XCTAssertEqual(inl[0].contentRange, r(1, 7))
        XCTAssertEqual(InlineScanner.scan("[no link] (x)").count, 0)
        XCTAssertEqual(InlineScanner.scan("[a](b c)").count, 0)
    }

    func testImage() {
        let inl = InlineScanner.scan("![alt text](img/p.png)")
        XCTAssertEqual(inl.map(\.kind), [.image(source: "img/p.png", alt: "alt text")])
        XCTAssertEqual(inl[0].markerRanges, [r(0, 2), r(10, 12)])
    }

    func testEscapes() {
        let inl = InlineScanner.scan("\\*not em\\* and \\`x")
        XCTAssertEqual(inl.map(\.kind), [.escape, .escape, .escape])
        XCTAssertEqual(inl[0].markerRanges, [r(0, 1)])
        XCTAssertEqual(inl[0].contentRange, r(1, 1))
        XCTAssertEqual(InlineScanner.scan("a\\b").count, 0)  // not punctuation
    }

    func testNonASCIIRanges() {
        let text = "Héllo 👋🏽 **wörld 🌍** and `cöde` [lïnk](ü)"
        let ns = text as NSString
        let inl = InlineScanner.scan(text)
        XCTAssertEqual(inl.map(\.kind), [.strong, .code, .link(url: "ü")])
        XCTAssertEqual(inl[0].range, ns.range(of: "**wörld 🌍**"))
        XCTAssertEqual(inl[0].contentRange, ns.range(of: "wörld 🌍"))
        XCTAssertEqual(inl[1].contentRange, ns.range(of: "cöde"))
        XCTAssertEqual(inl[2].contentRange, ns.range(of: "lïnk"))
    }

    func testDocumentInlinesUseBlockContent() {
        let doc = MarkdownDocument("# Title **b**\n- item *e*\n```\n**no**\n```\n")
        XCTAssertEqual(doc.inlines(in: doc.blocks[0]).map(\.kind), [.strong])
        XCTAssertEqual(doc.inlines(in: doc.blocks[1]).map(\.kind), [.emphasis])
        XCTAssertEqual(doc.inlines(in: doc.blocks[2]), [])
        // "* " bullet marker is not an emphasis delimiter
        XCTAssertEqual(MarkdownDocument("* a*b*").inlines(in: MarkdownDocument("* a*b*").blocks[0]).map(\.kind), [.emphasis])
    }
}
