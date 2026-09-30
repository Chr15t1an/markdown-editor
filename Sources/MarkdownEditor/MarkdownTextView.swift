import AppKit
import MarkdownCore

/// Format actions the Format menu sends to the first responder.
@MainActor @objc protocol MarkdownFormatActions {
    func toggleBold(_ sender: Any?)
    func toggleItalic(_ sender: Any?)
    func toggleInlineCode(_ sender: Any?)
    func toggleStrikethrough(_ sender: Any?)
    func insertLink(_ sender: Any?)
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

    @objc func setHeadingLevel(_ sender: Any?) {
        let level = (sender as? NSMenuItem)?.tag ?? (sender as? NSNumber)?.intValue ?? 0
        apply(EditCommands.setHeading(string, selectedRange(), level: level))
    }

    private func wrap(_ marker: String) { apply(EditCommands.toggleWrap(string, selectedRange(), marker: marker)) }

    // MARK: ⌘-click opens links

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let url = linkURL(at: event) {
            NSWorkspace.shared.open(url)
            return
        }
        super.mouseDown(with: event)
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

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if DropView.openableURL(from: sender) != nil { return .generic }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if DropView.openableURL(from: sender) != nil { return .generic }
        return super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let url = DropView.openableURL(from: sender) {
            onOpen?(url)
            return true
        }
        return super.performDragOperation(sender)
    }
}
