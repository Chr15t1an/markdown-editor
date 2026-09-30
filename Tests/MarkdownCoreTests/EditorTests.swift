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
