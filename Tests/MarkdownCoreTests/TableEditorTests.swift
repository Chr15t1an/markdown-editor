import AppKit
import XCTest
@testable import MarkdownCore
@testable import MarkdownEditor

/// Tables in the headless editor: hidden pipes line the cells up in columns while the caret is
/// outside the table; the whole table shows its source while the caret is in it.
@MainActor
final class TableEditorTests: XCTestCase {
    private func editor(_ text: String, width: CGFloat = 760) -> EditorViewController {
        let e = EditorViewController()
        e.loadView()
        e.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        e.textContainer.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        e.load(text)
        return e
    }

    /// Container x of the glyph for `char`.
    private func x(_ e: EditorViewController, _ char: Int) -> CGFloat {
        let lm = e.layoutManager
        lm.ensureLayout(for: e.textContainer)
        let g = lm.glyphIndexForCharacter(at: char)
        return lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil).minX + lm.location(forGlyphAt: g).x
    }

    private func hidden(_ e: EditorViewController, _ char: Int) -> Bool {
        e.layoutManager.ensureLayout(for: e.textContainer)
        return MarkerHidingLayoutDelegate.isHiddenGlyph(e.layoutManager, character: char)
    }

    private func loc(_ text: String, _ needle: String) -> Int { (text as NSString).range(of: needle).location }

    private let sample = "intro\n\n| Model | Job |\n|---|---|\n| Opus | Plans and reviews |\n| Sonnet | Executes the plan |\n\nafter\n"

    func testColumnsLineUpWhileCaretIsOutside() {
        let text = sample
        let e = editor(text)
        e.textView.setSelectedRange(NSRange(location: 0, length: 0))
        let col0 = ["Model", "Opus", "Sonnet"].map { x(e, loc(text, $0)) }
        let col1 = ["Job", "Plans", "Executes"].map { x(e, loc(text, $0)) }
        for v in col0 { XCTAssertEqual(v, col0[0], accuracy: 0.5) }
        for v in col1 { XCTAssertEqual(v, col1[0], accuracy: 0.5) }
        XCTAssertGreaterThan(col1[0] - col0[0], 40)
        // The header is bold, every row stays on one line.
        let font = e.textStorage.attribute(.font, at: loc(text, "Model"), effectiveRange: nil) as! NSFont
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
        let info = e.textStorage.attribute(.mdTable, at: loc(text, "Model"), effectiveRange: nil) as? TableInfo
        XCTAssertEqual(info?.fits, true)
        // Hidden pipes at a line start stay on their own line: one fragment per line.
        let lm = e.layoutManager
        var lines: [String] = []
        lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs)) { _, _, _, glyphs, _ in
            lines.append((text as NSString).substring(with: lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)))
        }
        XCTAssertEqual(lines, text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map { $0 + "\n" })
    }

    func testPipesHiddenOutsideAndWholeTableRevealedInside() {
        let text = sample
        let e = editor(text)
        let headerPipe = loc(text, "| Model")
        let delimiter = loc(text, "|---")
        let lastRowPipe = loc(text, "| Sonnet")
        e.textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(hidden(e, headerPipe))
        XCTAssertTrue(hidden(e, delimiter + 1))
        XCTAssertTrue(hidden(e, lastRowPipe))
        XCTAssertFalse(hidden(e, loc(text, "Model")))
        let plainX = x(e, loc(text, "Plans"))

        // Caret in the last row: every row of the table shows its pipes, the delimiter row too.
        e.textView.setSelectedRange(NSRange(location: loc(text, "plan |"), length: 0))
        XCTAssertFalse(hidden(e, headerPipe))
        XCTAssertFalse(hidden(e, delimiter + 1))
        XCTAssertFalse(hidden(e, lastRowPipe))
        XCTAssertNotEqual(x(e, loc(text, "Plans")), plainX)
        // Caret in the header row: same.
        e.textView.setSelectedRange(NSRange(location: loc(text, "Job"), length: 0))
        XCTAssertFalse(hidden(e, lastRowPipe))

        // Caret leaves: hidden again, columns back.
        e.textView.setSelectedRange(NSRange(location: loc(text, "after"), length: 0))
        XCTAssertTrue(hidden(e, headerPipe))
        XCTAssertEqual(x(e, loc(text, "Plans")), plainX, accuracy: 0.5)
    }

    func testHiddenDelimiterRowCollapses() {
        let text = sample
        let e = editor(text)
        let lm = e.layoutManager
        func height(_ char: Int) -> CGFloat {
            lm.ensureLayout(for: e.textContainer)
            return lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: char), effectiveRange: nil).height
        }
        let delimiter = loc(text, "|---")
        e.textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertEqual(height(delimiter), MarkerHidingLayoutDelegate.hiddenDelimiterHeight)
        XCTAssertGreaterThan(height(loc(text, "Opus")), 15)
        e.textView.setSelectedRange(NSRange(location: loc(text, "Opus"), length: 0))
        XCTAssertEqual(height(delimiter), height(loc(text, "Opus")), accuracy: 0.5)
    }

    func testEmptyBodyRowKeepsItsHeight() {
        let text = "| a | b |\n|---|---|\n||\n| c | d |\n\nend\n"
        let e = editor(text)
        e.textView.setSelectedRange(NSRange(location: loc(text, "end"), length: 0))
        let lm = e.layoutManager
        lm.ensureLayout(for: e.textContainer)
        func height(_ char: Int) -> CGFloat {
            lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: char), effectiveRange: nil).height
        }
        XCTAssertTrue(hidden(e, loc(text, "||")))                       // its pipes are hidden
        XCTAssertEqual(height(loc(text, "|---")), MarkerHidingLayoutDelegate.hiddenDelimiterHeight)
        XCTAssertEqual(height(loc(text, "||")), height(loc(text, "| c")), accuracy: 0.5)
    }

    func testHeaderRuleIsStrongerThanRowSeparators() {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                let (header, row) = EditorLayoutManager.tableRuleColors()
                let base = NSColor.separatorColor.usingColorSpace(.sRGB)!.alphaComponent
                XCTAssertGreaterThan(header.alphaComponent, row.alphaComponent)
                XCTAssertLessThan(row.alphaComponent, base + 0.001)        // scaled, not replaced
                XCTAssertGreaterThan(header.alphaComponent, base - 0.001)
            }
        }
    }

    func testRightAndCenterAlignment() {
        let text = "| a | b | c |\n|--:|:-:|---|\n| long text | wider cell text | x |\n\nend\n"
        let e = editor(text)
        e.textView.setSelectedRange(NSRange(location: loc(text, "end"), length: 0))
        let aStart = loc(text, "a |"), long = loc(text, "long text")
        // Right: right edges line up ("a" ends where "long text" ends).
        XCTAssertEqual(x(e, aStart + 1), x(e, long + 9), accuracy: 0.5)
        XCTAssertGreaterThan(x(e, aStart), x(e, long) + 20)
        // Center: midpoints line up within a point.
        let b = loc(text, "b |"), wide = loc(text, "wider cell text")
        let bMid = (x(e, b) + x(e, b + 1)) / 2
        let wideMid = (x(e, wide) + x(e, wide + 15)) / 2
        XCTAssertEqual(bMid, wideMid, accuracy: 1)
        // Unaligned: left edges line up.
        XCTAssertEqual(x(e, loc(text, "c |")), x(e, loc(text, "x |")), accuracy: 0.5)
    }

    func testShortAndLongRowsKeepTheGrid() {
        let text = "| A | B | C |\n|---|---|---|\n| 1 | 2 |\n| 4 | 5 | 6 | 7 |\n\nend\n"
        let e = editor(text)
        e.textView.setSelectedRange(NSRange(location: loc(text, "end"), length: 0))
        XCTAssertEqual(x(e, loc(text, "B")), x(e, loc(text, "2")), accuracy: 0.5)
        XCTAssertEqual(x(e, loc(text, "B")), x(e, loc(text, "5")), accuracy: 0.5)
        XCTAssertEqual(x(e, loc(text, "C")), x(e, loc(text, "6")), accuracy: 0.5)
        XCTAssertGreaterThan(x(e, loc(text, "7")), x(e, loc(text, "6")) + 20)   // outside the grid
    }

    func testNoOuterPipesAlign() {
        let text = "Name | Score\n--- | ---\nAnn | 10\nBartholomew | 7\n\nend\n"
        let e = editor(text)
        e.textView.setSelectedRange(NSRange(location: loc(text, "end"), length: 0))
        let scores = ["Score", "10", "7"].map { x(e, loc(text, $0)) }
        for v in scores { XCTAssertEqual(v, scores[0], accuracy: 0.5) }
        XCTAssertEqual(x(e, loc(text, "Name")), x(e, loc(text, "Ann")), accuracy: 0.5)
    }

    func testOverWideTableFallsBackToSource() {
        let text = "| Model | Job |\n|---|---|\n| Opus | Plans and reviews every single change before it ships |\n\nend\n"
        let e = editor(text, width: 260)
        e.textView.setSelectedRange(NSRange(location: loc(text, "end"), length: 0))
        let info = e.textStorage.attribute(.mdTable, at: 0, effectiveRange: nil) as? TableInfo
        XCTAssertEqual(info?.fits, false)
        XCTAssertFalse(hidden(e, 0))                      // pipes visible with the caret outside
        XCTAssertFalse(hidden(e, loc(text, "|---")))
        // The same table fits a normal column.
        e.textContainer.size = NSSize(width: 760, height: CGFloat.greatestFiniteMagnitude)
        e.restyleAll()
        XCTAssertTrue(hidden(e, 0))
    }

    func testStorageRoundTripsThroughCaretMovesAndEditUndo() {
        // The repro fixture (artifacts/repro/sample-tables.md): all five table shapes.
        let text = """
        # Table repro

        Christian's case — plain table:

        | Model | Job |
        |---|---|
        | Opus | Plans and reviews |
        | Sonnet | Executes the plan |

        Alignment row, inline styling in cells:

        | Left | Center | Right |
        |:-----|:------:|------:|
        | a | **bold** | 1 |
        | longer cell text | `code` | 1000 |

        Escaped pipes inside cells:

        | Expr | Meaning |
        | --- | --- |
        | `a \\| b` | a or b |
        | x \\| y | escaped pipe in text |

        No leading or trailing pipe:

        Name | Score
        --- | ---
        Ann | 10
        Bob | 7

        Uneven rows (short and long):

        | A | B | C |
        |---|---|---|
        | 1 | 2 |
        | 1 | 2 | 3 | 4 |

        After the tables, a normal paragraph.
        """
        let e = editor(text)
        let tv = e.textView!
        let length = (text as NSString).length
        for l in stride(from: 0, to: length, by: 7) { tv.setSelectedRange(NSRange(location: l, length: 0)) }
        XCTAssertEqual(e.text, text)
        let at = loc(text, "Opus") + 4
        tv.setSelectedRange(NSRange(location: at, length: 0))
        tv.insertText(" 4.1", replacementRange: tv.selectedRange())
        XCTAssertNotEqual(e.text, text)
        let undo = tv.undoManager!
        while undo.canUndo { undo.undo() }
        XCTAssertEqual(e.text, text)
        XCTAssertEqual(Array(e.text.utf8), Array(text.utf8))
    }

    func testEditingACellRealignsTheTable() {
        let text = sample
        let e = editor(text)
        let tv = e.textView!
        tv.setSelectedRange(NSRange(location: loc(text, "Opus") + 4, length: 0))
        tv.insertText(" 4.1 (newer and longer)", replacementRange: tv.selectedRange())
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        let t = e.text
        let col1 = ["Job", "Plans", "Executes"].map { x(e, loc(t, $0)) }
        for v in col1 { XCTAssertEqual(v, col1[0], accuracy: 0.5) }
        XCTAssertGreaterThan(col1[0], x(e, loc(t, "(newer and longer)")) + 100)
    }

    func testEscapedPipeInCodeSpanHidesItsBackslash() {
        let text = "| Expr | Meaning |\n| --- | --- |\n| `a \\| b` | a or b |\n| x \\| y | text |\n\nend\n"
        let e = editor(text)
        e.textView.setSelectedRange(NSRange(location: loc(text, "end"), length: 0))
        let codeSlash = loc(text, "\\| b`"), textSlash = loc(text, "\\| y")
        XCTAssertTrue(hidden(e, codeSlash))              // GFM: `a \| b` shows as a | b
        XCTAssertFalse(hidden(e, codeSlash + 1))         // the pipe itself stays
        XCTAssertTrue(hidden(e, textSlash))              // outside a code span: as before
        // The hidden backslash takes no width, so the next column still lines up.
        let col1 = ["Meaning", "a or b", "text"].map { x(e, loc(text, $0)) }
        for v in col1 { XCTAssertEqual(v, col1[0], accuracy: 0.5) }
        // Caret on the escape: the backslash shows, like any other escape.
        e.textView.setSelectedRange(NSRange(location: codeSlash + 1, length: 0))
        XCTAssertFalse(hidden(e, codeSlash))
        XCTAssertEqual(e.text, text)
    }

    func testCodeSpanOutsideATableKeepsItsBackslash() {
        // CommonMark: no escapes inside a code span outside a table.
        let doc = MarkdownDocument("a `b \\| c` d\n")
        let code = doc.inlines(in: doc.blocks[0]).first { $0.kind == .code }
        XCTAssertNotNil(code)
        XCTAssertEqual(code?.children, [])
        let table = MarkdownDocument("| `b \\| c` |\n|---|\n")
        let cell = table.inlines(in: table.blocks[0]).first { $0.kind == .code }
        XCTAssertEqual(cell?.children.map(\.kind), [.escape])
        XCTAssertEqual(cell?.children.first?.markerRanges, [NSRange(location: 5, length: 1)])
    }

    func testMixedLeadingPipesAlignColumnZero() {
        let cases = [
            "Name | Score\n--- | ---\n| Ann | 10 |\n| Bartholomew | 7 |\nCy | 3\n\nend\n",
            "| Name | Score |\n|---|---|\nAnn | 10\n| Bartholomew | 7 |\n\nend\n",
            "Name | Score\n--- | ---\n  |  Ann | 10 |\n\nend\n",
        ]
        for text in cases {
            let e = editor(text)
            e.textView.setSelectedRange(NSRange(location: loc(text, "end"), length: 0))
            let names = ["Name", "Ann", "Bartholomew", "Cy"].filter { loc(text, $0) != NSNotFound }
            let col0 = names.map { x(e, loc(text, $0)) }
            let col1 = ["Score", "10", "7", "3"].filter { loc(text, $0) != NSNotFound }.map { x(e, loc(text, $0)) }
            for v in col0 { XCTAssertEqual(v, col0[0], accuracy: 0.5, text) }
            for v in col1 { XCTAssertEqual(v, col1[0], accuracy: 0.5, text) }
            XCTAssertGreaterThan(col1[0] - col0[0], 30, text)
            // The space after a leading pipe is hidden with the table and shown with it.
            let pipe = loc(text, "| Ann") == NSNotFound ? loc(text, "| Bartholomew") : loc(text, "| Ann")
            let afterPipe = pipe == NSNotFound ? loc(text, "|  Ann") + 1 : pipe + 1
            XCTAssertTrue(hidden(e, afterPipe), text)
            e.textView.setSelectedRange(NSRange(location: loc(text, "Score"), length: 0))
            XCTAssertFalse(hidden(e, afterPipe), text)
            XCTAssertEqual(e.text, text)
        }
    }

    func testAllLeadingPipesKeepTheirGutter() {
        // Not mixed: column 0 still starts a gutter in and no whitespace is hidden.
        let text = sample
        let e = editor(text)
        e.textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertFalse(hidden(e, loc(text, "| Opus") + 1))
        let lineStart = x(e, loc(text, "| Opus"))
        XCTAssertEqual(x(e, loc(text, "Opus")) - lineStart, MarkdownStyler.tableGutter, accuracy: 0.5)
    }
}
