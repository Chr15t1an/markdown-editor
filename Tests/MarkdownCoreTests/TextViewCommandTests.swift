import AppKit
import XCTest
@testable import MarkdownEditor

@MainActor
final class TextViewCommandTests: XCTestCase {
    func testReturnContinuesListAndOneUndoRevertsIt() {
        let e = makeEditor("- a")
        let tv = e.textView!
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        tv.insertNewline(nil)
        XCTAssertEqual(e.text, "- a\n- ")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 6, length: 0))
        tv.undoManager!.undo()
        XCTAssertEqual(e.text, "- a")
    }

    func testTypingThenReturnUndoesSeparately() {
        let e = makeEditor("")
        let tv = e.textView!
        let undo = tv.undoManager!
        // No event loop runs in a test, so group per "event" by hand, as AppKit does per keystroke.
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        func event(_ body: () -> Void) { undo.beginUndoGrouping(); body(); undo.endUndoGrouping() }
        event { tv.insertText("- one", replacementRange: tv.selectedRange()) }
        event { tv.insertNewline(nil) }
        event { tv.insertText("two", replacementRange: tv.selectedRange()) }
        XCTAssertEqual(e.text, "- one\n- two")
        undo.undo()   // "two"
        XCTAssertEqual(e.text, "- one\n- ")
        undo.undo()   // the continuation
        XCTAssertEqual(e.text, "- one")
    }

    func testBoldActionAndTab() {
        let e = makeEditor("a word\n- item")
        let tv = e.textView!
        tv.setSelectedRange(NSRange(location: 2, length: 4))
        tv.toggleBold(nil)
        XCTAssertEqual(e.text, "a **word**\n- item")
        tv.setSelectedRange(NSRange(location: (e.text as NSString).length, length: 0))
        tv.insertTab(nil)
        XCTAssertEqual(e.text, "a **word**\n  - item")
        tv.insertBacktab(nil)
        XCTAssertEqual(e.text, "a **word**\n- item")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.insertTab(nil)  // not a list: a literal tab
        XCTAssertEqual(e.text, "\ta **word**\n- item")
    }

    func testHeadingAction() {
        let e = makeEditor("title")
        let tv = e.textView!
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        tv.setHeadingLevel(NSNumber(value: 2))
        XCTAssertEqual(e.text, "## title")
        let font = e.textStorage.attribute(.font, at: 4, effectiveRange: nil) as! NSFont
        XCTAssertEqual(font.pointSize, 24)
    }
}
