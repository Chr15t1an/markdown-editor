import AppKit
import XCTest
@testable import MarkdownCore
@testable import MarkdownEditor

/// Typing in a table restyles only the edited row and defers the other rows' pipe widths until
/// the caret leaves the table (review S2). Whatever the edit, once the caret is outside the table
/// its attributes must be exactly what a full restyle of the same text gives.
@MainActor
final class TableIncrementalTests: XCTestCase {
    private func editor(_ text: String, width: CGFloat = 760) -> EditorViewController {
        let e = EditorViewController()
        e.loadView()
        e.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        e.textContainer.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        e.load(text)
        return e
    }

    private func loc(_ text: String, _ needle: String) -> Int { (text as NSString).range(of: needle).location }

    private let sample = """
        intro

        | Model | Job | Notes |
        |:------|:---:|------:|
        | **Opus** | Plans and reviews | `x \\| y` |
        | Sonnet | Executes the plan | 2 |
        | Haiku | Fast | 3 | extra |
        | a | b | c |

        after

        """

    /// Every character's attributes equal those of a fresh full restyle of the same text.
    private func assertMatchesFullRestyle(_ e: EditorViewController, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let text = e.text
        let fresh = NSTextStorage(string: text, attributes: e.styler.theme.bodyAttributes)
        e.styler.styleAll(fresh, document: MarkdownDocument(text))
        let live = e.textStorage
        XCTAssertEqual(live.string, fresh.string, file: file, line: line)
        var mismatches: [String] = []
        for i in 0..<fresh.length {
            let a = live.attributes(at: i, effectiveRange: nil) as NSDictionary
            let b = fresh.attributes(at: i, effectiveRange: nil) as NSDictionary
            if !a.isEqual(b) {
                let keys = Set((a.allKeys + b.allKeys).compactMap { $0 as? NSAttributedString.Key })
                    .filter { !((a[$0] as AnyObject?)?.isEqual(b[$0]) ?? (b[$0] == nil)) }
                mismatches.append("\(i) '\((text as NSString).substring(with: NSRange(location: i, length: 1)))': \(keys.map(\.rawValue).sorted())")
            }
        }
        XCTAssertTrue(mismatches.isEmpty, "\(message): \(mismatches.count) characters differ, first: \(mismatches.prefix(5))",
                      file: file, line: line)
    }

    private func type(_ e: EditorViewController, _ s: String, at location: Int, replacing length: Int = 0) {
        let tv = e.textView!
        tv.setSelectedRange(NSRange(location: location, length: length))
        tv.insertText(s, replacementRange: tv.selectedRange())
    }

    private func leave(_ e: EditorViewController) {
        e.textView.setSelectedRange(NSRange(location: loc(e.text, "after"), length: 0))
    }

    func testRowEditsMatchAFullRestyleOnceTheCaretLeaves() {
        typealias Edit = (name: String, apply: (EditorViewController) -> Void)
        let edits: [Edit] = [
            ("narrow cell", { e in self.type(e, "!", at: self.loc(e.text, "b |") + 1) }),
            ("widen a column", { e in self.type(e, " and a much longer note", at: self.loc(e.text, "Fast") + 4) }),
            ("shrink the widest cell", { e in self.type(e, "", at: self.loc(e.text, "Plans and reviews"), replacing: 10) }),
            ("header", { e in self.type(e, "Model name", at: self.loc(e.text, "Model"), replacing: 5) }),
            ("delimiter, same alignment", { e in self.type(e, "-", at: self.loc(e.text, "|:---:") + 2) }),
            ("delimiter, new alignment", { e in self.type(e, ":", at: self.loc(e.text, "------:|") - 1, replacing: 1) }),
            ("inline span", { e in self.type(e, "**", at: self.loc(e.text, "Executes")) }),
            ("extra cell", { e in self.type(e, " | more", at: self.loc(e.text, "| c |") + 4) }),
            ("merge two rows", { e in self.type(e, "", at: self.loc(e.text, "2 |\n") + 3, replacing: 1) }),
            ("split a row", { e in self.type(e, "\n", at: self.loc(e.text, "| b |")) }),
            ("blank line ends the table", { e in self.type(e, "\n", at: self.loc(e.text, "| a |")) }),
            ("paragraph joins the table", { e in self.type(e, "", at: self.loc(e.text, "| c |\n") + 5, replacing: 1) }),
        ]
        for edit in edits {
            let e = editor(sample)
            edit.apply(e)
            leave(e)
            assertMatchesFullRestyle(e, edit.name)
        }
        // Several edits in a row, in different rows, before leaving.
        let e = editor(sample)
        for edit in edits.prefix(8) { edit.apply(e) }
        leave(e)
        assertMatchesFullRestyle(e, "sequence")
    }

    /// Code-span `\|` (an escape child of the code span) and mixed leading-pipe tables (collapsed
    /// leading whitespace, which follows the grid) on the row path.
    func testCodeSpanPipesAndMixedLeadingPipesMatchAFullRestyle() {
        let code = "| Expr | Meaning |\n| --- | --- |\n| `a \\| b` | a or b |\n| x \\| y | text |\n| `c \\| d` | last |\n\nafter\n"
        let mixed = "Name | Score\n--- | ---\n| Ann | 10 |\n| Bartholomew | 7 |\nCy | 3\n  |  Dee | 4 |\n\nafter\n"
        typealias Edit = (name: String, text: String, apply: (EditorViewController) -> Void)
        let edits: [Edit] = [
            ("code span: edit before the escape", code, { e in self.type(e, "zz", at: self.loc(e.text, "a \\|") + 1) }),
            ("code span: row above a code span", code, { e in self.type(e, "longer ", at: self.loc(e.text, "Meaning")) }),
            ("code span: new escape", code, { e in self.type(e, " \\| e", at: self.loc(e.text, "c \\| d") + 6) }),
            ("code span: widen", code, { e in self.type(e, " and something much wider", at: self.loc(e.text, "text")) }),
            ("mixed: widen column 0 in a piped row", mixed, { e in self.type(e, "-Smythe", at: self.loc(e.text, "Bartholomew") + 11) }),
            ("mixed: shrink column 0", mixed, { e in self.type(e, "", at: self.loc(e.text, "Bartholomew") + 4, replacing: 7) }),
            ("mixed: indent an unpiped row", mixed, { e in self.type(e, "   ", at: self.loc(e.text, "Cy")) }),
            ("mixed: unpiped row widens", mixed, { e in self.type(e, "rus the Great", at: self.loc(e.text, "Cy") + 2) }),
            ("mixed: space after a leading pipe", mixed, { e in self.type(e, "  ", at: self.loc(e.text, "| Ann") + 1) }),
            ("mixed: header", mixed, { e in self.type(e, "Full name", at: self.loc(e.text, "Name"), replacing: 4) }),
        ]
        for edit in edits {
            let e = editor(edit.text)
            edit.apply(e)
            leave(e)
            assertMatchesFullRestyle(e, edit.name)
        }
        for text in [code, mixed] {
            let e = editor(text)
            for edit in edits where edit.text == text { edit.apply(e) }
            leave(e)
            assertMatchesFullRestyle(e, "sequence")
        }
    }

    /// The grid moves and comes back while another row was written against the moved grid:
    /// leaving must still realign that row.
    func testGridThatComesBackStillRealignsRowsEditedInBetween() {
        let e = editor(sample)
        type(e, " much wider than before", at: loc(e.text, "Fast") + 4)   // grid widens
        type(e, "!", at: loc(e.text, "| c |") + 3)                         // row written on the wide grid
        let wide = (e.text as NSString).range(of: " much wider than before")
        type(e, "", at: wide.location, replacing: wide.length)            // grid back
        leave(e)
        assertMatchesFullRestyle(e, "grid back")
    }

    func testTableThatStopsFittingAndFitsAgain() {
        let e = editor(sample, width: 420)
        let long = String(repeating: "wide ", count: 20)
        type(e, long, at: loc(e.text, "Fast") + 4)
        leave(e)
        assertMatchesFullRestyle(e, "unfit")
        let info = e.textStorage.attribute(.mdTable, at: loc(e.text, "Model"), effectiveRange: nil) as? TableInfo
        XCTAssertEqual(info?.fits, false)
        type(e, "", at: loc(e.text, long), replacing: (long as NSString).length)
        leave(e)
        assertMatchesFullRestyle(e, "fits again")
    }

    /// An edit made while the selection is outside the table (Replace All) aligns it at once.
    func testEditOutsideTheSelectionAlignsImmediately() {
        let e = editor(sample)
        let tv = e.textView!
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        let r = NSRange(location: loc(e.text, "Fast"), length: 4)
        if tv.shouldChangeText(in: r, replacementString: "Fast and much much wider") {
            e.textStorage.replaceCharacters(in: r, with: "Fast and much much wider")
            tv.didChangeText()
        }
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertFalse(NSLocationInRange(tv.selectedRange().location, NSRange(location: loc(e.text, "| Model"), length: 200)))
        assertMatchesFullRestyle(e, "replace outside")
    }

    /// Container x of the glyph for `char`.
    private func x(_ e: EditorViewController, _ char: Int) -> CGFloat {
        let lm = e.layoutManager
        lm.ensureLayout(for: e.textContainer)
        let g = lm.glyphIndexForCharacter(at: char)
        return lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil).minX + lm.location(forGlyphAt: g).x
    }

    private func largeTable(rows: Int) -> String {
        var text = "intro\n\n| Name | Role | Team | Notes | Score |\n|---|:-:|---|---|--:|\n"
        for i in 0..<rows { text += "| person \(i) | engineer | **core** | `note` here \(i) | \(i * 7) |\n" }
        return text + "\nafter\n"
    }

    /// Review S2: ~250 ms per keystroke at 1,000 rows before. Budget 50 ms (debug build), both
    /// for a cell that keeps the grid and for one that widens its column on every keystroke.
    func testTypingInALargeTableIsFast() {
        let text = largeTable(rows: 1000)
        let e = editor(text)
        let tv = e.textView!
        func median(at location: Int, _ s: String) -> Double {
            tv.setSelectedRange(NSRange(location: location, length: 0))
            e.layoutManager.ensureLayout(for: e.textContainer)
            var times: [Double] = []
            for _ in 0..<15 {
                let start = Date()
                tv.insertText(s, replacementRange: tv.selectedRange())
                e.layoutManager.ensureLayout(forCharacterRange: NSRange(location: tv.selectedRange().location, length: 0))
                times.append(Date().timeIntervalSince(start))
            }
            return times.sorted()[times.count / 2]
        }
        // Deleting in a narrow cell keeps the grid; typing in the Role column widens it each time.
        let keep = median(at: loc(text, "here 500 ") + 9, "")
        let widen = median(at: loc(e.text, "engineer | **core** | `note` here 500") + 8, "x")
        // Near the top every row below moves: the worst case for re-marking inline spans.
        let top = median(at: loc(e.text, "person 0 ") + 8, "y")
        print("large table: \(String(format: "%.1f", keep * 1000)) ms per keystroke (grid kept), "
              + "\(String(format: "%.1f", widen * 1000)) ms (grid widened), \(String(format: "%.1f", top * 1000)) ms (first row)")
        XCTAssertLessThan(keep, 0.050)
        XCTAssertLessThan(widen, 0.050)
        XCTAssertLessThan(top, 0.050)

        // Leaving the table brings the deferred grid in: every row lines up with the edited one.
        let start = Date()
        tv.setSelectedRange(NSRange(location: loc(e.text, "after"), length: 0))
        print("large table: leaving after edits \(String(format: "%.1f", Date().timeIntervalSince(start) * 1000)) ms")
        let t = e.text
        // Notes: left-aligned starts line up. Score (right-aligned): ends line up.
        let notes = ["Notes", "`note` here 0 ", "`note` here 500", "`note` here 999 "].map { x(e, loc(t, $0)) }
        for v in notes { XCTAssertEqual(v, notes[0], accuracy: 0.5) }
        let scoreEnds = ["Score |", "| 0 |", "| 3500 |", "| 6993 |"].map { needle -> CGFloat in
            let r = (t as NSString).range(of: needle)
            return x(e, r.location + r.length - 2)
        }
        for v in scoreEnds { XCTAssertEqual(v, scoreEnds[0], accuracy: 0.5) }
        // The column after Role (widened by the edits) starts every row at the same x.
        let team = [x(e, loc(t, "Team"))] + ["core** | `note` here 0 ", "core** | `note` here 500", "core** | `note` here 999 "]
            .map { x(e, loc(t, $0)) }
        for v in team { XCTAssertEqual(v, team[0], accuracy: 0.5) }
        XCTAssertTrue(MarkerHidingLayoutDelegate.isHiddenGlyph(e.layoutManager, character: loc(t, "| person 999")))
    }

    /// Caret in a large table after typing: every row shows its pipes, including far-away rows.
    func testWholeTableStaysRevealedWhileTyping() {
        let text = largeTable(rows: 300)
        let e = editor(text)
        type(e, "x", at: loc(text, "person 150 ") + 9)
        e.layoutManager.ensureLayout(for: e.textContainer)
        for needle in ["| Name", "|---", "| person 0 ", "| person 299 "] {
            XCTAssertFalse(MarkerHidingLayoutDelegate.isHiddenGlyph(e.layoutManager, character: loc(e.text, needle)), needle)
        }
        leave(e)
        for needle in ["| Name", "| person 0 ", "| person 299 "] {
            XCTAssertTrue(MarkerHidingLayoutDelegate.isHiddenGlyph(e.layoutManager, character: loc(e.text, needle)), needle)
        }
        assertMatchesFullRestyle(e, "large table after leaving")
    }
}
