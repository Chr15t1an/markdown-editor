import XCTest
@testable import MarkdownCore

final class EditCommandsTests: XCTestCase {
    private func r(_ l: Int, _ n: Int) -> NSRange { NSRange(location: l, length: n) }

    private func apply(_ text: String, _ edit: TextEdit?) -> (String, NSRange)? {
        guard let edit else { return nil }
        return (edit.applied(to: text), edit.newSelection)
    }

    func testBoldWrapAndUnwrap() {
        let (t1, s1) = apply("a word b", EditCommands.toggleWrap("a word b", r(2, 4), marker: "**"))!
        XCTAssertEqual(t1, "a **word** b")
        XCTAssertEqual(s1, r(4, 4))
        let (t2, s2) = apply(t1, EditCommands.toggleWrap(t1, s1, marker: "**"))!
        XCTAssertEqual(t2, "a word b")
        XCTAssertEqual(s2, r(2, 4))
        // Markers inside the selection also unwrap.
        XCTAssertEqual(apply(t1, EditCommands.toggleWrap(t1, r(2, 8), marker: "**"))!.0, "a word b")
    }

    func testEmptySelectionInsertsPair() {
        let (t, s) = apply("ab", EditCommands.toggleWrap("ab", r(1, 0), marker: "`"))!
        XCTAssertEqual(t, "a``b")
        XCTAssertEqual(s, r(2, 0))
        XCTAssertEqual(apply(t, EditCommands.toggleWrap(t, s, marker: "`"))!.0, "ab")
    }

    func testItalicAndStrike() {
        XCTAssertEqual(apply("x", EditCommands.toggleWrap("x", r(0, 1), marker: "*"))!.0, "*x*")
        XCTAssertEqual(apply("x", EditCommands.toggleWrap("x", r(0, 1), marker: "~~"))!.0, "~~x~~")
        // Italic inside bold: `**x**` with x selected wraps (does not eat the bold).
        XCTAssertEqual(apply("**x**", EditCommands.toggleWrap("**x**", r(2, 1), marker: "*"))!.0, "***x***")
        XCTAssertEqual(apply("***x***", EditCommands.toggleWrap("***x***", r(3, 1), marker: "*"))!.0, "**x**")
    }

    func testMakeLink() {
        let (t, s) = apply("see docs", EditCommands.makeLink("see docs", r(4, 4)))!
        XCTAssertEqual(t, "see [docs]()")
        XCTAssertEqual(s, r(11, 0))
        XCTAssertEqual(apply("", EditCommands.makeLink("", r(0, 0)))!.1, r(1, 0))
    }

    func testHeadings() {
        let (t1, s1) = apply("title\nnext", EditCommands.setHeading("title\nnext", r(3, 0), level: 2))!
        XCTAssertEqual(t1, "## title\nnext")
        XCTAssertEqual(s1, r(6, 0))
        let (t2, _) = apply(t1, EditCommands.setHeading(t1, s1, level: 1))!
        XCTAssertEqual(t2, "# title\nnext")
        XCTAssertEqual(apply(t2, EditCommands.setHeading(t2, r(4, 0), level: 0))!.0, "title\nnext")
        XCTAssertEqual(apply("a\n# b", EditCommands.setHeading("a\n# b", r(4, 0), level: 3))!.0, "a\n### b")
    }

    func testNewlineContinuesLists() {
        XCTAssertEqual(apply("- a", EditCommands.newline("- a", r(3, 0)))!.0, "- a\n- ")
        XCTAssertEqual(apply("- a", EditCommands.newline("- a", r(3, 0)))!.1, r(6, 0))
        XCTAssertEqual(apply("* a\n", EditCommands.newline("* a\n", r(3, 0)))!.0, "* a\n* \n")
        XCTAssertEqual(apply("9. nine", EditCommands.newline("9. nine", r(7, 0)))!.0, "9. nine\n10. ")
        XCTAssertEqual(apply("3) x", EditCommands.newline("3) x", r(4, 0)))!.0, "3) x\n4) ")
        XCTAssertEqual(apply("- [x] done", EditCommands.newline("- [x] done", r(10, 0)))!.0, "- [x] done\n- [ ] ")
        XCTAssertEqual(apply("> q", EditCommands.newline("> q", r(3, 0)))!.0, "> q\n> ")
        XCTAssertEqual(apply("    - deep", EditCommands.newline("    - deep", r(10, 0)))!.0, "    - deep\n    - ")
    }

    func testNewlineSplitsItemAtCaret() {
        XCTAssertEqual(apply("- ab", EditCommands.newline("- ab", r(3, 0)))!.0, "- a\n- b")
    }

    func testEmptyItemEndsList() {
        let (t, s) = apply("- a\n- ", EditCommands.newline("- a\n- ", r(6, 0)))!
        XCTAssertEqual(t, "- a\n")
        XCTAssertEqual(s, r(4, 0))
        XCTAssertEqual(apply("1. a\n2. \nz", EditCommands.newline("1. a\n2. \nz", r(8, 0)))!.0, "1. a\n\nz")
        XCTAssertEqual(apply("- [ ] ", EditCommands.newline("- [ ] ", r(6, 0)))!.0, "")
    }

    func testNewlineDefaults() {
        XCTAssertNil(EditCommands.newline("plain", r(5, 0)))
        XCTAssertNil(EditCommands.newline("# h", r(3, 0)))
        XCTAssertNil(EditCommands.newline("```\n- in code\n```", r(13, 0)))
        XCTAssertNil(EditCommands.newline("- a", r(1, 0)))        // caret inside the marker
        XCTAssertNil(EditCommands.newline("- a", r(2, 1)))        // selection
    }

    func testIndentOutdent() {
        let (t1, s1) = apply("- a\n- b", EditCommands.indent("- a\n- b", r(7, 0)))!
        XCTAssertEqual(t1, "- a\n  - b")
        XCTAssertEqual(s1, r(9, 0))
        let (t2, s2) = apply(t1, EditCommands.outdent(t1, s1))!
        XCTAssertEqual(t2, "- a\n- b")
        XCTAssertEqual(s2, r(7, 0))
        XCTAssertNil(EditCommands.outdent("- a", r(3, 0)))       // nothing to remove
        XCTAssertNil(EditCommands.indent("plain", r(2, 0)))      // not a list: default tab
        // Multi-line selection indents every item.
        XCTAssertEqual(apply("- a\n1. b\n", EditCommands.indent("- a\n1. b\n", r(0, 7)))!.0, "  - a\n  1. b\n")
    }
}
