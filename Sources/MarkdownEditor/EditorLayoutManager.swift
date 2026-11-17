import AppKit
import MarkdownCore

/// Draws block chrome that has no glyphs: horizontal rules, quote bars, code-block backgrounds,
/// table rules, images and task-list checkboxes.
final class EditorLayoutManager: NSLayoutManager {
    weak var hiding: MarkerHidingLayoutDelegate?
    /// Draws an image into the space reserved below an image-only paragraph.
    var drawImage: ((ImageInfo, NSRect) -> Void)?
    /// Draws a task-list checkbox (checked or not) into a rect, while the task's marker is hidden.
    var drawTaskBox: ((Bool, NSRect) -> Void)?
    /// Set by the editor from its styler's theme.
    var theme = Theme()

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let width = container.size.width - 2 * container.lineFragmentPadding

        storage.enumerateAttribute(.mdCodeBlock, in: chars) { value, range, _ in
            guard value != nil else { return }
            let rect = blockRect(range, origin: origin, width: width, container: container)
            theme.codeBackground.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: -theme.codeBlockPadding),
                         xRadius: theme.codeBlockRadius, yRadius: theme.codeBlockRadius).fill()
        }
        storage.enumerateAttribute(.mdQuote, in: chars) { value, range, _ in
            guard value != nil else { return }
            let rect = blockRect(range, origin: origin, width: width, container: container)
            theme.dividerColor.setFill()
            let inset = theme.quoteBarInset
            NSRect(x: rect.minX + inset, y: rect.minY + inset, width: theme.quoteBarWidth, height: rect.height - 2 * inset).fill()
        }
        storage.enumerateAttribute(.mdHorizontalRule, in: chars) { value, range, _ in
            guard value != nil, markersHidden(at: range.location, in: storage) else { return }
            let rect = blockRect(range, origin: origin, width: width, container: container)
            theme.dividerColor.setFill()
            NSRect(x: rect.minX, y: floor(rect.midY), width: rect.width, height: theme.ruleWidth).fill()
        }
        var tablesDrawn = Set<Int>()
        storage.enumerateAttribute(.mdTable, in: chars) { value, range, _ in
            guard let info = value as? TableInfo, info.fits || info.wrap != nil else { return }
            var table = NSRange()
            _ = storage.attribute(.mdTable, at: range.location, longestEffectiveRange: &table,
                                  in: NSRange(location: 0, length: storage.length))
            guard tablesDrawn.insert(table.location).inserted else { return }
            if let wrap = info.wrap {
                drawWrappedTable(table, info, wrap, visible: chars, storage: storage, origin: origin, container: container)
            } else {
                drawTableRules(table, info, storage: storage, origin: origin, container: container)
            }
        }
        storage.enumerateAttribute(.mdImage, in: chars) { value, range, _ in
            // Drawn whether or not the caret has revealed the source: the space stays reserved.
            guard let info = value as? ImageInfo else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { return }
            let line = lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let frag = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let x = origin.x + container.lineFragmentPadding
            let offset = theme.imageGap / 2   // the image sits half the reserved gap below its line
            let below = NSRect(x: x, y: origin.y + line.maxY + offset, width: width, height: frag.maxY - line.maxY - offset)
            drawImage?(info, below)
        }
        var boxesDrawn = Set<Int>()
        storage.enumerateAttribute(.mdTaskBox, in: chars) { value, range, _ in
            guard value is TaskBox, let slot = taskBoxSlot(forTaskAt: range.location),
                  boxesDrawn.insert(slot.start).inserted, markersHidden(at: slot.start, in: storage) else { return }
            drawTaskBox?(slot.checked, slot.box.offsetBy(dx: origin.x, dy: origin.y))
        }
    }

    /// The checkbox slot of the task item at `charIndex` (any character carrying `.mdTaskBox`), in
    /// container coordinates: `slot` (bullet through `]`, the first line's height) is the click
    /// target, `box` the `taskBoxSize` square drawn centred in it on the text's cap height.
    func taskBoxSlot(forTaskAt charIndex: Int) -> (slot: NSRect, box: NSRect, checked: Bool, start: Int)? {
        guard let storage = textStorage, charIndex < storage.length else { return nil }
        let line = (storage.string as NSString).lineRange(for: NSRange(location: charIndex, length: 0))
        var range = NSRange()
        guard let info = storage.attribute(.mdTaskBox, at: charIndex, longestEffectiveRange: &range, in: line) as? TaskBox
        else { return nil }
        let g = glyphIndexForCharacter(at: range.location)
        guard g < numberOfGlyphs else { return nil }
        let frag = lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        let used = lineFragmentUsedRect(forGlyphAt: g, effectiveRange: nil)
        let loc = location(forGlyphAt: g)
        let slot = NSRect(x: frag.minX + loc.x, y: frag.minY, width: info.slotWidth, height: used.height)
        let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? theme.bodyFont
        let baseline = frag.minY + loc.y
        let side = theme.taskBoxSize
        let box = NSRect(x: slot.midX - side / 2, y: baseline - font.capHeight / 2 - side / 2, width: side, height: side)
        return (slot, box, info.checked, range.location)
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
        // The header rule reads stronger than the row separators (Theme scales the divider's alpha).
        theme.tableHeaderRuleColor.setFill()
        NSRect(x: x, y: origin.y + floor(delimiter.midY), width: width, height: theme.ruleWidth).fill()
        // Between body rows: halfway between the baseline of the row above and the cap-height
        // top of the row below (the line-height multiple puts its extra space above the text).
        theme.tableRowRuleColor.setFill()
        let body = Array(lines.dropFirst(2))
        for (above, below) in zip(body, body.dropFirst()) {
            let bottom = textMetrics(above, storage).baseline, top = textMetrics(below, storage).capTop
            NSRect(x: x, y: origin.y + floor((bottom + top) / 2), width: width, height: theme.ruleWidth).fill()
        }
    }

    /// A wrapped table while its source is hidden: each row's line is as tall as its wrapped
    /// cells, and the cells are drawn here, with the same rules as a grid (a header rule through
    /// the delimiter strip, hairlines between body rows). Only rows in `visible` are drawn.
    private func drawWrappedTable(_ table: NSRange, _ info: TableInfo, _ wrap: WrappedTable, visible: NSRange,
                                  storage: NSTextStorage, origin: NSPoint, container: NSTextContainer) {
        guard markersHidden(at: table.location, in: storage) else { return }
        let rows = BlockScanner.tableRows(storage.string as NSString, in: table)
        guard rows.count >= 2 else { return }
        let ns = storage.string as NSString
        func fragment(_ row: TableRow) -> NSRect {
            lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: row.line.location), effectiveRange: nil)
        }
        func shown(_ row: TableRow) -> Bool {
            NSIntersectionRange(ns.lineRange(for: row.line), visible).length > 0
        }
        let left = origin.x + container.lineFragmentPadding
        let width = min(wrap.width, container.size.width - 2 * container.lineFragmentPadding)
        let padding = theme.tableWrappedRowPadding
        let columns = wrap.columnWidths.count
        for (i, row) in rows.enumerated() where i != 1 && shown(row) {
            let frag = fragment(row)
            for (c, cell) in row.cells.prefix(columns).enumerated() where cell.length > 0 {
                let alignment = c < info.alignments.count ? info.alignments[c] : .none
                let string = WrappedTable.cellString(cell, storage, alignment: alignment)
                let rect = NSRect(x: left + frag.minX + wrap.columnStarts[c], y: origin.y + frag.minY + padding,
                                  width: wrap.columnWidths[c], height: max(0, frag.height - 2 * padding))
                string.draw(with: rect, options: WrappedTable.drawingOptions)
            }
        }
        if shown(rows[1]) {
            let delimiter = fragment(rows[1])
            theme.tableHeaderRuleColor.setFill()
            NSRect(x: left + delimiter.minX, y: origin.y + floor(delimiter.midY), width: width, height: theme.ruleWidth).fill()
        }
        theme.tableRowRuleColor.setFill()
        let body = Array(rows.dropFirst(2))
        for (above, below) in zip(body, body.dropFirst()) where shown(above) || shown(below) {
            let frag = fragment(above)
            NSRect(x: left + frag.minX, y: origin.y + floor(frag.maxY), width: width, height: theme.ruleWidth).fill()
        }
    }

    /// Container-space baseline and cap-height top of a line's text (its first font).
    private func textMetrics(_ line: NSRange, _ storage: NSTextStorage) -> (baseline: CGFloat, capTop: CGFloat) {
        let g = glyphIndexForCharacter(at: line.location)
        let frag = lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        let baseline = frag.minY + location(forGlyphAt: g).y
        let font = storage.attribute(.font, at: line.location, effectiveRange: nil) as? NSFont ?? theme.bodyFont
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
