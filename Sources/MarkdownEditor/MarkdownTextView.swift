import AppKit
import MarkdownCore

/// Format actions the Format menu sends to the first responder.
@MainActor @objc protocol MarkdownFormatActions {
    func toggleBold(_ sender: Any?)
    func toggleItalic(_ sender: Any?)
    func toggleInlineCode(_ sender: Any?)
    func toggleStrikethrough(_ sender: Any?)
    func insertLink(_ sender: Any?)
    /// Ticks or unticks the task item on the caret's line.
    func toggleTask(_ sender: Any?)
    /// Heading level from the sender's tag (0 = paragraph).
    func setHeadingLevel(_ sender: Any?)
}

/// The editor's text view: markdown keyboard behavior (list continuation, Tab indent, format
/// shortcuts), ⌘-click on links, and folder/file drops that open instead of inserting paths.
final class MarkdownTextView: NSTextView, MarkdownFormatActions {
    var onOpen: ((URL) -> Void)?
    /// Folder of the open file, for resolving relative link destinations on ⌘-click.
    var baseURL: URL?

    // MARK: Applying edits

    /// Applies an edit as one undoable change.
    func apply(_ edit: TextEdit) {
        guard let storage = textStorage else { return }
        breakUndoCoalescing()
        guard shouldChangeText(in: edit.replacementRange, replacementString: edit.replacement) else { return }
        storage.replaceCharacters(in: edit.replacementRange,
                                  with: NSAttributedString(string: edit.replacement, attributes: typingAttributes))
        didChangeText()
        setSelectedRange(edit.newSelection)
        breakUndoCoalescing()
    }

    private var hasMarkedTextNow: Bool { hasMarkedText() }

    // MARK: Keys

    override func insertNewline(_ sender: Any?) {
        if !hasMarkedTextNow, let edit = EditCommands.newline(string, selectedRange()) {
            apply(edit)
        } else {
            super.insertNewline(sender)
        }
    }

    override func insertTab(_ sender: Any?) {
        if !hasMarkedTextNow, let edit = EditCommands.indent(string, selectedRange()) {
            apply(edit)
        } else {
            super.insertTab(sender)
        }
    }

    override func insertBacktab(_ sender: Any?) {
        if !hasMarkedTextNow, let edit = EditCommands.outdent(string, selectedRange()) {
            apply(edit)
        } else {
            super.insertBacktab(sender)
        }
    }

    // MARK: Format actions

    @objc func toggleBold(_ sender: Any?) { wrap("**") }
    @objc func toggleItalic(_ sender: Any?) { wrap("*") }
    @objc func toggleInlineCode(_ sender: Any?) { wrap("`") }
    @objc func toggleStrikethrough(_ sender: Any?) { wrap("~~") }
    @objc func insertLink(_ sender: Any?) { apply(EditCommands.makeLink(string, selectedRange())) }

    @objc func toggleTask(_ sender: Any?) {
        if let edit = EditCommands.toggleTask(string, at: selectedRange().location, selection: selectedRange()) {
            apply(edit)
        } else {
            NSSound.beep()
        }
    }

    @objc func setHeadingLevel(_ sender: Any?) {
        let level = (sender as? NSMenuItem)?.tag ?? (sender as? NSNumber)?.intValue ?? 0
        apply(EditCommands.setHeading(string, selectedRange(), level: level))
    }

    private func wrap(_ marker: String) { apply(EditCommands.toggleWrap(string, selectedRange(), marker: marker)) }

    // MARK: Clicks: task boxes toggle, ⌘-click opens links

    override func mouseDown(with event: NSEvent) {
        if handleTaskClick(at: convert(event.locationInWindow, from: nil), clickCount: event.clickCount,
                           modifiers: event.modifierFlags) { return }
        if event.modifierFlags.contains(.command), let url = linkURL(at: event) {
            NSWorkspace.shared.open(url)
            return
        }
        super.mouseDown(with: event)
    }

    /// A plain click on a task's checkbox slot (box drawn or source shown) toggles it and is
    /// swallowed: no caret move. Double and triple clicks there are swallowed without toggling
    /// again. With a modifier (⌘ ⇧ ⌥ ⌃) the click is the text view's. Returns whether it was handled.
    func handleTaskClick(at viewPoint: NSPoint, clickCount: Int, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard modifiers.intersection([.command, .shift, .option, .control]).isEmpty,
              let storage = textStorage, storage.length > 0,
              let layout = layoutManager as? EditorLayoutManager, let container = textContainer else { return false }
        let origin = textContainerOrigin
        let point = NSPoint(x: viewPoint.x - origin.x, y: viewPoint.y - origin.y)
        let index = layout.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
        guard index < storage.length else { return false }
        let line = (string as NSString).lineRange(for: NSRange(location: index, length: 0))
        var slotLocation: Int?
        storage.enumerateAttribute(.mdTaskBox, in: line) { value, range, stop in
            if value is TaskBox { slotLocation = range.location; stop.pointee = true }
        }
        guard let slotLocation, let slot = layout.taskBoxSlot(forTaskAt: slotLocation),
              slot.slot.contains(point) else { return false }
        if clickCount == 1, let edit = EditCommands.toggleTask(string, at: slotLocation, selection: selectedRange()) {
            apply(edit)
        }
        return true
    }

    private func linkURL(at event: NSEvent) -> URL? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        guard index < storage.length,
              let dest = storage.attribute(.mdLinkURL, at: index, effectiveRange: nil) as? String else { return nil }
        if let url = URL(string: dest), url.scheme != nil { return url }
        guard let base = baseURL else { return nil }
        let folder = URL(fileURLWithPath: base.path, isDirectory: true)
        return URL(fileURLWithPath: dest.removingPercentEncoding ?? dest, relativeTo: folder).standardizedFileURL
    }

    // MARK: Drops
    // An image dropped on the note keeps NSTextView's handling instead of navigating away (decision 14).

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if DropView.openableURL(from: sender, includingImages: false) != nil { return .generic }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if DropView.openableURL(from: sender, includingImages: false) != nil { return .generic }
        return super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let url = DropView.openableURL(from: sender, includingImages: false) {
            onOpen?(url)
            return true
        }
        return super.performDragOperation(sender)
    }
}
