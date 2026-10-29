import AppKit
import MarkdownCore

/// Window content view that accepts a dropped folder, markdown or image file anywhere in the window.
final class DropView: NSView {
    var onOpen: ((URL) -> Void)?
    var theme: Theme {
        get { highlight.theme }
        set { highlight.theme = newValue; highlight.needsDisplay = true }
    }
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

    /// The first dragged URL the window can open. `includingImages: false` leaves image files out
    /// (the note's text view keeps its own handling for those).
    static func openableURL(from info: NSDraggingInfo, includingImages: Bool = true) -> URL? {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.first { url in
            guard let target = OpenTarget.resolve(url) else { return false }
            return includingImages || !(target.file.map(ImageFile.isImage) ?? false)
        }
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
    var theme = Theme()
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        theme.accentColor.setStroke()
        let inset = theme.dropHighlightInset, radius = theme.dropHighlightRadius
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: radius, yRadius: radius)
        path.lineWidth = theme.dropHighlightStroke
        path.stroke()
    }
}
