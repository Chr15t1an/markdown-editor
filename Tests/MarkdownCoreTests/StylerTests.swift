import AppKit
import XCTest
@testable import MarkdownCore

final class StylerTests: XCTestCase {
    private func styled(_ text: String) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        MarkdownStyler().styleAll(storage, document: MarkdownDocument(text))
        return storage
    }

    private func font(_ s: NSTextStorage, _ at: Int) -> NSFont { s.attribute(.font, at: at, effectiveRange: nil) as! NSFont }
    private func reveal(_ s: NSTextStorage, _ at: Int) -> MarkerReveal? { s.attribute(.mdMarker, at: at, effectiveRange: nil) as? MarkerReveal }

    func testHeading() {
        let s = styled("# Title\nbody")
        XCTAssertEqual(font(s, 3).pointSize, 28)
        XCTAssertEqual(reveal(s, 0)?.scope, .line)
        XCTAssertEqual(reveal(s, 1)?.scope, .line)
        XCTAssertNil(reveal(s, 2))
        XCTAssertEqual(font(s, 9).pointSize, 15)
    }

    func testBoldMarkersAreSpanMarkers() {
        let s = styled("a **b** c")
        XCTAssertTrue(font(s, 4).fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertFalse(font(s, 0).fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(reveal(s, 2)?.scope, .span)
        XCTAssertEqual(reveal(s, 2)?.range, NSRange(location: 2, length: 5))
        XCTAssertEqual(reveal(s, 5)?.scope, .span)
        XCTAssertNil(reveal(s, 4))
    }

    func testItalicInsideBoldHasBothTraits() {
        let s = styled("**a *b* c**")
        let traits = font(s, 5).fontDescriptor.symbolicTraits
        XCTAssertTrue(traits.contains(.bold) && traits.contains(.italic))
    }

    func testLink() {
        let text = "go [here](https://x.io) now"
        let s = styled(text)
        let here = (text as NSString).range(of: "here")
        XCTAssertEqual(s.attribute(.foregroundColor, at: here.location, effectiveRange: nil) as? NSColor, NSColor.linkColor)
        XCTAssertEqual(s.attribute(.mdLinkURL, at: here.location, effectiveRange: nil) as? String, "https://x.io")
        let tail = (text as NSString).range(of: "](https://x.io)")
        for i in tail.location..<(tail.location + tail.length) { XCTAssertEqual(reveal(s, i)?.scope, .span) }
        XCTAssertEqual(reveal(s, 3)?.scope, .span)  // "["
    }

    func testCodeSpanMonospaced() {
        let s = styled("x `code` y")
        XCTAssertTrue(font(s, 4).fontDescriptor.symbolicTraits.contains(.monoSpace))
        XCTAssertNotNil(s.attribute(.backgroundColor, at: 4, effectiveRange: nil))
    }

    func testBlockquoteIndentAndListBulletNotHidden() {
        let s = styled("> quote\n- item\n")
        let p = s.attribute(.paragraphStyle, at: 3, effectiveRange: nil) as! NSParagraphStyle
        XCTAssertEqual(p.headIndent, 16)
        XCTAssertEqual(reveal(s, 0)?.scope, .line)
        XCTAssertNil(reveal(s, 8))        // "-" of the list item
        XCTAssertNotNil(s.attribute(.mdQuote, at: 3, effectiveRange: nil))
    }

    func testFencedCodeAndHorizontalRule() {
        let s = styled("```\nlet x\n```\n---\n")
        XCTAssertEqual(reveal(s, 0)?.scope, .line)
        XCTAssertTrue(font(s, 5).fontDescriptor.symbolicTraits.contains(.monoSpace))
        XCTAssertNotNil(s.attribute(.mdCodeBlock, at: 5, effectiveRange: nil))
        XCTAssertNotNil(s.attribute(.mdHorizontalRule, at: 14, effectiveRange: nil))
        XCTAssertEqual(reveal(s, 14)?.scope, .line)
    }

    func testRestyleRangeClearsOldAttributes() {
        let storage = NSTextStorage(string: "**b**")
        let styler = MarkdownStyler()
        styler.styleAll(storage, document: MarkdownDocument("**b**"))
        storage.replaceCharacters(in: NSRange(location: 0, length: 2), with: "")
        styler.style(storage, document: MarkdownDocument(storage.string), in: NSRange(location: 0, length: 1))
        XCTAssertNil(storage.attribute(.mdMarker, at: 1, effectiveRange: nil))
        XCTAssertFalse((storage.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).fontDescriptor.symbolicTraits.contains(.bold))
    }
}
