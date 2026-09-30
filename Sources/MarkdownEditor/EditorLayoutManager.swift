import AppKit
import MarkdownCore

/// Draws block chrome that has no glyphs: horizontal rules, quote bars, code-block backgrounds.
final class EditorLayoutManager: NSLayoutManager {
    weak var hiding: MarkerHidingLayoutDelegate?
    /// Draws an image into the space reserved below an image-only paragraph.
    var drawImage: ((ImageInfo, NSRect) -> Void)?

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let width = container.size.width - 2 * container.lineFragmentPadding

        storage.enumerateAttribute(.mdCodeBlock, in: chars) { value, range, _ in
            guard value != nil else { return }
            let rect = blockRect(range, origin: origin, width: width, container: container)
            NSColor.quaternarySystemFill.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: -2), xRadius: 5, yRadius: 5).fill()
        }
        storage.enumerateAttribute(.mdQuote, in: chars) { value, range, _ in
            guard value != nil else { return }
            let rect = blockRect(range, origin: origin, width: width, container: container)
            NSColor.separatorColor.setFill()
            NSRect(x: rect.minX + 2, y: rect.minY + 2, width: 3, height: rect.height - 4).fill()
        }
        storage.enumerateAttribute(.mdHorizontalRule, in: chars) { value, range, _ in
            guard value != nil, markersHidden(at: range.location, in: storage) else { return }
            let rect = blockRect(range, origin: origin, width: width, container: container)
            NSColor.separatorColor.setFill()
            NSRect(x: rect.minX, y: floor(rect.midY), width: rect.width, height: 1).fill()
        }
        storage.enumerateAttribute(.mdImage, in: chars) { value, range, _ in
            // Drawn whether or not the caret has revealed the source: the space stays reserved.
            guard let info = value as? ImageInfo else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { return }
            let line = lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let frag = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let x = origin.x + container.lineFragmentPadding
            let below = NSRect(x: x, y: origin.y + line.maxY + 4, width: width, height: frag.maxY - line.maxY - 4)
            drawImage?(info, below)
        }
    }

    private func markersHidden(at location: Int, in storage: NSTextStorage) -> Bool {
        guard location < storage.length,
              let reveal = storage.attribute(.mdMarker, at: location, effectiveRange: nil) as? MarkerReveal else { return false }
        return hiding?.isHidden(reveal) ?? true
    }

    /// Union of the line fragments of `range`, spanning the text container's full width.
    private func blockRect(_ range: NSRange, origin: NSPoint, width: CGFloat, container: NSTextContainer) -> NSRect {
        let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = NSRect.null
        enumerateLineFragments(forGlyphRange: glyphs) { frag, _, _, _, _ in rect = rect.union(frag) }
        if rect.isNull { return .zero }
        return NSRect(x: origin.x + container.lineFragmentPadding, y: origin.y + rect.minY, width: width, height: rect.height)
    }
}
