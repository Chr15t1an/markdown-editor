import AppKit
import MarkdownCore

/// Draws block chrome that has no glyphs: horizontal rules, quote bars, code-block backgrounds,
/// table rules.
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
        var tablesDrawn = Set<Int>()
        storage.enumerateAttribute(.mdTable, in: chars) { value, range, _ in
            guard let info = value as? TableInfo, info.fits else { return }
            var table = NSRange()
            _ = storage.attribute(.mdTable, at: range.location, longestEffectiveRange: &table,
                                  in: NSRange(location: 0, length: storage.length))
            guard tablesDrawn.insert(table.location).inserted else { return }
            drawTableRules(table, info, storage: storage, origin: origin, container: container)
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

    /// A table while its pipes are hidden: a rule through the (hidden) delimiter row under the
    /// header, and a hairline between body rows, as wide as the grid.
    private func drawTableRules(_ table: NSRange, _ info: TableInfo, storage: NSTextStorage, origin: NSPoint,
                                container: NSTextContainer) {
        let ns = storage.string as NSString
        var lines: [NSRange] = []
        var at = table.location
        while at < table.location + table.length {
            let line = ns.lineRange(for: NSRange(location: at, length: 0))
            lines.append(line)
            at = line.location + line.length
        }
        guard lines.count >= 2, markersHidden(at: lines[1].location, in: storage) else { return }
        func fragment(_ line: NSRange) -> NSRect {
            lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: line.location), effectiveRange: nil)
        }
        let delimiter = fragment(lines[1])
        let x = origin.x + delimiter.minX + container.lineFragmentPadding
        let width = min(info.width, container.size.width - 2 * container.lineFragmentPadding)
        // The header rule reads stronger than the row separators. separatorColor is mostly
        // transparent (its alpha is ~0.1), so scale its alpha rather than replace it.
        let (headerRule, rowRule) = Self.tableRuleColors()
        headerRule.setFill()
        NSRect(x: x, y: origin.y + floor(delimiter.midY), width: width, height: 1).fill()
        // Between body rows: halfway between the baseline of the row above and the cap-height
        // top of the row below (the line-height multiple puts its extra space above the text).
        rowRule.setFill()
        let body = Array(lines.dropFirst(2))
        for (above, below) in zip(body, body.dropFirst()) {
            let bottom = textMetrics(above, storage).baseline, top = textMetrics(below, storage).capTop
            NSRect(x: x, y: origin.y + floor((bottom + top) / 2), width: width, height: 1).fill()
        }
    }

    /// Header rule and row separator colours: separatorColor's alpha scaled up and down, resolved
    /// for the current (drawing) appearance.
    static func tableRuleColors() -> (header: NSColor, row: NSColor) {
        let base = NSColor.separatorColor.usingColorSpace(.sRGB) ?? NSColor(white: 0.5, alpha: 0.1)
        let alpha = base.alphaComponent
        return (base.withAlphaComponent(min(1, alpha * 2)), base.withAlphaComponent(alpha * 0.8))
    }

    /// Container-space baseline and cap-height top of a line's text (its first font).
    private func textMetrics(_ line: NSRange, _ storage: NSTextStorage) -> (baseline: CGFloat, capTop: CGFloat) {
        let g = glyphIndexForCharacter(at: line.location)
        let frag = lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        let baseline = frag.minY + location(forGlyphAt: g).y
        let font = storage.attribute(.font, at: line.location, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 15)
        return (baseline, baseline - font.capHeight)
    }

    private func markersHidden(at location: Int, in storage: NSTextStorage) -> Bool {
        guard location < storage.length,
              let reveal = storage.attribute(.mdMarker, at: location, effectiveRange: nil) as? MarkerReveal else { return false }
        return hiding?.isHidden(reveal, at: location) ?? true
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
