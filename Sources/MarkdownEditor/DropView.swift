import AppKit
import MarkdownCore

/// Window content view that accepts a dropped folder or markdown file anywhere in the window.
final class DropView: NSView {
    var onOpen: ((URL) -> Void)?
    private let highlight = DropHighlightView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        highlight.isHidden = true
        highlight.autoresizingMask = [.width, .height]
        highlight.frame = bounds
        addSubview(highlight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Keeps the highlight overlay above the content that is added later.
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if subview !== highlight { addSubview(highlight, positioned: .above, relativeTo: nil) }
    }

    static func openableURL(from info: NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.first { OpenTarget.resolve($0) != nil }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard Self.openableURL(from: sender) != nil else { return [] }
        highlight.isHidden = false
        return .generic
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { highlight.isHidden = true }
    override func draggingEnded(_ sender: NSDraggingInfo) { highlight.isHidden = true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlight.isHidden = true
        guard let url = Self.openableURL(from: sender) else { return false }
        onOpen?(url)
        return true
    }
}

private final class DropHighlightView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 8, yRadius: 8)
        path.lineWidth = 3
        path.stroke()
    }
}
