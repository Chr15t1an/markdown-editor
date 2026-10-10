import AppKit
import XCTest
@testable import MarkdownCore
@testable import MarkdownEditor

@MainActor
func makeEditor(_ text: String) -> EditorViewController {
    let editor = EditorViewController()
    editor.loadView()
    editor.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    editor.load(text)
    return editor
}

@MainActor
final class HidingTests: XCTestCase {
    private func isNull(_ e: EditorViewController, _ char: Int) -> Bool {
        let lm = e.layoutManager
        lm.ensureLayout(for: e.textContainer)
        return MarkerHidingLayoutDelegate.isHiddenGlyph(lm, character: char)
    }

    /// x position of the glyph for `char` within its line fragment.
    private func x(_ e: EditorViewController, _ char: Int) -> CGFloat {
        let lm = e.layoutManager
        lm.ensureLayout(for: e.textContainer)
        return lm.location(forGlyphAt: lm.glyphIndexForCharacter(at: char)).x
    }

    func testBoldMarkersHiddenUntilCaretEntersSpan() {
        let e = makeEditor("plain line\na **b** c\n")
        e.textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(isNull(e, 13))
        XCTAssertTrue(isNull(e, 14))
        XCTAssertTrue(isNull(e, 16))
        XCTAssertFalse(isNull(e, 15))   // "b"
        let hiddenX = x(e, 15)

        e.textView.setSelectedRange(NSRange(location: 15, length: 0))
        XCTAssertFalse(isNull(e, 13))
        XCTAssertFalse(isNull(e, 16))
        XCTAssertGreaterThan(x(e, 15) - hiddenX, 8)   // "**" now takes space before "b"

        // Caret in the same line but outside the span: hidden again.
        e.textView.setSelectedRange(NSRange(location: 11, length: 0))
        XCTAssertTrue(isNull(e, 13))
    }

    func testHeadingMarkerHiddenUnlessCaretOnLine() {
        let e = makeEditor("# Title\n\nbody\n")
        e.textView.setSelectedRange(NSRange(location: 10, length: 0))
        XCTAssertTrue(isNull(e, 0))
        XCTAssertTrue(isNull(e, 1))
        XCTAssertFalse(isNull(e, 2))
        e.textView.setSelectedRange(NSRange(location: 5, length: 0))
        XCTAssertFalse(isNull(e, 0))
    }

    /// Hidden markers at a line start must stay in that line's fragment (plain null glyphs
    /// were attached to the previous line, moving the caret and block chrome).
    func testHiddenLineStartMarkersStayOnTheirLine() {
        let text = "- a\n\n> A quote\n\n```\nlet x\n```\n\n---\nend\n"
        let e = makeEditor(text)
        e.textView.setSelectedRange(NSRange(location: 0, length: 0))
        let lm = e.layoutManager
        lm.ensureLayout(for: e.textContainer)
        var starts: [String] = []
        lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs)) { _, _, _, glyphs, _ in
            let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            starts.append((text as NSString).substring(with: chars))
        }
        XCTAssertEqual(starts, ["- a\n", "\n", "> A quote\n", "\n", "```\n", "let x\n", "```\n", "\n", "---\n", "end\n"])
        XCTAssertTrue(isNull(e, 5))  // ">" hidden
    }

    func testTypingClosesBold() {
        let e = makeEditor("")
        let tv = e.textView!
        for ch in ["*", "*", "b", "*", "*"] { tv.insertText(ch, replacementRange: tv.selectedRange()) }
        XCTAssertEqual(e.text, "**b**")
        let font = e.textStorage.attribute(.font, at: 2, effectiveRange: nil) as! NSFont
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
        tv.insertText(" x", replacementRange: tv.selectedRange())
        tv.setSelectedRange(NSRange(location: 7, length: 0))
        XCTAssertTrue(isNull(e, 0))
        XCTAssertTrue(isNull(e, 3))
    }
}

@MainActor
final class EditingTests: XCTestCase {
    func testTypingInHeadingKeepsHeadingFont() {
        let e = makeEditor("# Title\n")
        let tv = e.textView!
        tv.setSelectedRange(NSRange(location: 7, length: 0))
        tv.insertText(" more", replacementRange: tv.selectedRange())
        let font = e.textStorage.attribute(.font, at: 9, effectiveRange: nil) as! NSFont
        XCTAssertEqual(font.pointSize, 28)
        XCTAssertEqual(e.text, "# Title more\n")
    }

    func testUndoAfterBoldingRestoresTextAndStyles() {
        let e = makeEditor("word\n")
        let tv = e.textView!
        tv.setSelectedRange(NSRange(location: 4, length: 0))
        tv.insertText("**", replacementRange: NSRange(location: 4, length: 0))
        tv.insertText("**", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(e.text, "**word**\n")
        XCTAssertTrue((e.textStorage.attribute(.font, at: 3, effectiveRange: nil) as! NSFont).fontDescriptor.symbolicTraits.contains(.bold))
        let undo = tv.undoManager!
        XCTAssertNotNil(undo)
        while undo.canUndo { undo.undo() }
        XCTAssertEqual(e.text, "word\n")
        XCTAssertFalse((e.textStorage.attribute(.font, at: 1, effectiveRange: nil) as! NSFont).fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertNil(e.textStorage.attribute(.mdMarker, at: 0, effectiveRange: nil))
    }

    func testRestyleDoesNotMoveSelection() {
        let e = makeEditor("para\n\ntext\n")
        let tv = e.textView!
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.insertText("```\n", replacementRange: tv.selectedRange())   // opens a fence: restyles to EOF
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 4, length: 0))
        XCTAssertNotNil(e.textStorage.attribute(.mdCodeBlock, at: e.textStorage.length - 2, effectiveRange: nil))
        tv.insertText("x", replacementRange: tv.selectedRange())
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 5, length: 0))
    }
}

/// Markers in blocks after an edit are not restyled; their reveal ranges must follow the edit.
@MainActor
final class StaleMarkerOffsetTests: XCTestCase {
    private func isNull(_ e: EditorViewController, _ char: Int) -> Bool {
        e.layoutManager.ensureLayout(for: e.textContainer)
        return MarkerHidingLayoutDelegate.isHiddenGlyph(e.layoutManager, character: char)
    }

    func testSpanMarkerAfterInsertionFollowsTheEdit() {
        // "first\n\nsecond\n\na **b** c\n" — the bold span starts at 17.
        let e = makeEditor("first\n\nsecond\n\na **b** c\n")
        let tv = e.textView!
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        tv.insertText("12345", replacementRange: tv.selectedRange())
        // Bold span is now 22..<27 ("**b**"); markers at 22, 23, 25, 26.
        let r = e.textStorage.attribute(.mdMarker, at: 22, effectiveRange: nil) as? MarkerReveal
        XCTAssertEqual(r?.range(at: 22), NSRange(location: 22, length: 5))
        // Caret just before the span's old (unshifted) start: markers must stay hidden.
        tv.setSelectedRange(NSRange(location: 18, length: 0))
        XCTAssertTrue(isNull(e, 22))
        XCTAssertTrue(isNull(e, 26))
        // Caret inside the shifted span: markers shown.
        tv.setSelectedRange(NSRange(location: 24, length: 0))
        XCTAssertFalse(isNull(e, 22))
        XCTAssertFalse(isNull(e, 26))
    }

    func testSpanMarkerAfterDeletionFollowsTheEdit() {
        let e = makeEditor("first line\n\na `code` z\n")
        let tv = e.textView!
        tv.setSelectedRange(NSRange(location: 5, length: 5))   // " line"
        tv.insertText("", replacementRange: tv.selectedRange())
        // "first\n\na `code` z\n": code span 9..<15, backticks at 9 and 14.
        XCTAssertEqual(e.text, "first\n\na `code` z\n")
        tv.setSelectedRange(NSRange(location: 16, length: 0))   // on "z", outside the span
        XCTAssertTrue(isNull(e, 9))
        XCTAssertTrue(isNull(e, 14))
        tv.setSelectedRange(NSRange(location: 11, length: 0))
        XCTAssertFalse(isNull(e, 9))
        XCTAssertFalse(isNull(e, 14))
    }

    func testLineMarkerAfterInsertionFollowsTheEdit() {
        let e = makeEditor("intro\n\n# Head\n\nbody\n")
        let tv = e.textView!
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        tv.insertText(" text that is long", replacementRange: tv.selectedRange())   // +18
        // "# Head\n" now at 25..<32. Caret in the body paragraph: "#" hidden.
        let body = (e.text as NSString).range(of: "body").location
        tv.setSelectedRange(NSRange(location: body + 1, length: 0))
        XCTAssertTrue(isNull(e, 25))
        tv.setSelectedRange(NSRange(location: 28, length: 0))
        XCTAssertFalse(isNull(e, 25))
    }
}
