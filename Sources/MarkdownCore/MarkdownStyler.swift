import AppKit

extension NSAttributedString.Key {
    /// On every syntax marker character. Value: `MarkerReveal` — when the marker is shown.
    public static let mdMarker = NSAttributedString.Key("md.marker")
    /// On a horizontal-rule line (drawn as a separator while its markers are hidden).
    public static let mdHorizontalRule = NSAttributedString.Key("md.hr")
    /// On blockquote lines (a bar is drawn at the leading edge).
    public static let mdQuote = NSAttributedString.Key("md.quote")
    /// On fenced-code blocks (a full-width background is drawn).
    public static let mdCodeBlock = NSAttributedString.Key("md.codeBlock")
    /// On link text. Value: the destination string (⌘-click opens it).
    public static let mdLinkURL = NSAttributedString.Key("md.link")
    /// On an image-only paragraph. Value: `ImageInfo`.
    public static let mdImage = NSAttributedString.Key("md.image")
    /// On a whole table block. Value: `TableInfo`.
    public static let mdTable = NSAttributedString.Key("md.table")
    /// On a table's separator pipes. Value: `NSNumber` — the width the hidden pipe takes, so the
    /// cells after it line up in columns. Lives on the character, so it moves with edits.
    public static let mdPipeWidth = NSAttributedString.Key("md.pipeWidth")
    /// On a table's delimiter row (`|---|---|`), which collapses to a thin strip while hidden.
    public static let mdTableDelimiter = NSAttributedString.Key("md.tableDelimiter")
}

/// When a marker is visible: `.span` markers show while the selection touches the span
/// (inline syntax); `.line` markers show while the selection touches the block (heading `#`,
/// quote `>`, fence lines, `---`).
///
/// Blocks after an edit are not restyled, so a value must stay right when its characters move:
/// a `.span` value stores its span relative to the character carrying it (one value per
/// character), and a `.line` value stores no range at all (its own block is the one that counts).
public final class MarkerReveal: NSObject, @unchecked Sendable {
    public enum Scope: Equatable, Sendable { case span, line }
    public let scope: Scope
    /// `.span`: start of the span minus the index of the character carrying this value. `.line`: 0.
    public let offset: Int
    /// `.span`: the span's length. `.line`: 0.
    public let length: Int

    /// `range` is the absolute span (ignored for `.line`); `charIndex` is the character this
    /// value is attached to.
    public init(_ scope: Scope, _ range: NSRange, at charIndex: Int) {
        self.scope = scope
        self.offset = scope == .span ? range.location - charIndex : 0
        self.length = scope == .span ? range.length : 0
    }

    /// The `.span` range, for the value read at `charIndex`.
    public func range(at charIndex: Int) -> NSRange { NSRange(location: charIndex + offset, length: length) }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? MarkerReveal else { return false }
        return scope == other.scope && offset == other.offset && length == other.length
    }

    public override var hash: Int { offset &* 31 &+ length &+ (scope == .span ? 1 : 2) }

    /// Whether the marker at `charIndex` is shown for `selection`, given the ranges of the blocks
    /// it touches.
    public func isRevealed(at charIndex: Int, selection: NSRange, blockRanges: [NSRange]) -> Bool {
        switch scope {
        case .span:
            let range = range(at: charIndex)
            let end = range.location + range.length
            if selection.length == 0 { return selection.location >= range.location && selection.location <= end }
            return NSIntersectionRange(selection, range).length > 0
        case .line:
            // A line marker lies inside the block it reveals with, and blocks do not overlap: it
            // shows exactly when its own block is a revealed one.
            return blockRanges.contains { NSLocationInRange(charIndex, $0) }
        }
    }
}

/// An image-only paragraph's source, resolved by the editor.
public final class ImageInfo: NSObject, @unchecked Sendable {
    public let source: String
    public let alt: String
    public let lineRange: NSRange
    public init(source: String, alt: String, lineRange: NSRange) {
        self.source = source
        self.alt = alt
        self.lineRange = lineRange
    }
    public override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? ImageInfo else { return false }
        return o.source == source && NSEqualRanges(o.lineRange, lineRange)
    }
    public override var hash: Int { source.hashValue ^ lineRange.location }
}

/// A table's grid geometry, from its cell widths and the column width available.
public final class TableInfo: NSObject, @unchecked Sendable {
    public let alignments: [TableAlignment]
    /// False when a row does not fit the column: the table then shows as source (pipes visible).
    public let fits: Bool
    /// The grid's right edge, from the start of each row's line (padding excluded).
    public let width: CGFloat
    /// Column starts then column widths: every row's pipe widths follow from these and the row.
    let grid: [CGFloat]
    /// Set when a row restyle wrote a row against a different grid: `alignTables` must rewrite
    /// the table even if the grid has since come back to `grid`. Not part of equality.
    var pendingAlign = false

    public convenience init(alignments: [TableAlignment], fits: Bool, width: CGFloat) {
        self.init(alignments: alignments, fits: fits, width: width, grid: [])
    }
    init(alignments: [TableAlignment], fits: Bool, width: CGFloat, grid: [CGFloat]) {
        self.alignments = alignments
        self.fits = fits
        self.width = width
        self.grid = grid
    }
    public override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? TableInfo else { return false }
        return o.alignments == alignments && o.fits == fits && o.width == width && o.grid == grid
    }
    public override var hash: Int { alignments.count &* 31 &+ Int(width) &+ (fits ? 1 : 0) }
}

/// Derives display attributes from the markdown text. Styles are always recomputed from the
/// text (never stored), so undo, reload and external edits need no bookkeeping.
public struct MarkdownStyler: @unchecked Sendable {
    public var theme: Theme
    /// Extra space (below the line) for an image-only paragraph, keyed by source; set by the editor.
    public var imageSpacing: (ImageInfo) -> CGFloat? = { _ in nil }
    /// Width a table row may use (the text column minus line padding); set by the editor. Nil or
    /// 0 (no layout yet): tables are laid out unconstrained, and restyled when the width is known.
    public var tableWidth: () -> CGFloat? = { nil }
    public init(theme: Theme = Theme()) { self.theme = theme }

    /// Measured table-row widths, shared by copies of this styler.
    let tableRowCache = TableRowCache()

    private static let managedKeys: [NSAttributedString.Key] = [
        .mdMarker, .mdHorizontalRule, .mdQuote, .mdCodeBlock, .mdLinkURL, .mdImage, .mdTable, .mdPipeWidth, .mdTableDelimiter,
        .strikethroughStyle, .backgroundColor, .underlineStyle, .link, .kern,
    ]

    /// Restyles every block intersecting `range` (whole blocks). Returns the range styled.
    /// `edited` (optional) is where the characters changed; a table edited inside one row then
    /// restyles just that row when the rest of the table is still styled for it (review S2).
    @discardableResult
    public func style(_ storage: NSTextStorage, document: MarkdownDocument, in range: NSRange,
                      edited: NSRange? = nil) -> NSRange {
        guard storage.length == document.length else { return NSRange(location: 0, length: 0) }
        guard let indexes = document.blockIndexes(intersecting: range) else { return NSRange(location: 0, length: 0) }
        let first = document.blocks[indexes.lowerBound].range
        let last = document.blocks[indexes.upperBound].range
        let styled = NSUnionRange(first, last)
        storage.beginEditing()
        for i in indexes {
            let block = document.blocks[i]
            if let edited, restyleTableRow(block, edited: edited, in: storage, document: document) { continue }
            styleBlock(block, in: storage, document: document)
        }
        storage.endEditing()
        return styled
    }

    /// Restyles the whole document.
    public func styleAll(_ storage: NSTextStorage, document: MarkdownDocument) {
        guard storage.length == document.length else { return }
        storage.beginEditing()
        let all = NSRange(location: 0, length: storage.length)
        for key in Self.managedKeys { storage.removeAttribute(key, range: all) }
        storage.setAttributes(theme.bodyAttributes, range: all)
        for block in document.blocks { styleBlock(block, in: storage, document: document) }
        storage.endEditing()
    }

    /// The attributes new text in a block of `kind` should be typed with.
    public func typingAttributes(for kind: BlockKind?) -> [NSAttributedString.Key: Any] {
        var attrs = theme.bodyAttributes
        guard let kind else { return attrs }
        let (font, paragraph, color) = base(for: kind, markerWidth: 0)
        attrs[.font] = font
        attrs[.paragraphStyle] = paragraph
        attrs[.foregroundColor] = color
        return attrs
    }

    // MARK: Blocks

    private func base(for kind: BlockKind, markerWidth: CGFloat) -> (NSFont, NSParagraphStyle, NSColor) {
        switch kind {
        case .heading(let level):
            return (theme.headingFont(level: level),
                    theme.paragraphStyle(spacingBefore: theme.headingSpacing(level: level), lineHeightMultiple: theme.headingLineHeightMultiple),
                    theme.textColor)
        case .bulletItem, .orderedItem, .taskItem:
            return (theme.bodyFont, theme.paragraphStyle(headIndent: markerWidth), theme.textColor)
        case .blockquote:
            return (theme.bodyFont, theme.paragraphStyle(headIndent: theme.quoteIndent, firstLineHeadIndent: theme.quoteIndent), theme.quoteColor)
        case .fencedCode:
            return (theme.codeFont, theme.paragraphStyle(headIndent: theme.codeBlockIndent, firstLineHeadIndent: theme.codeBlockIndent,
                                                         lineHeightMultiple: theme.codeLineHeightMultiple), theme.textColor)
        default:
            return (theme.bodyFont, theme.paragraphStyle(), theme.textColor)
        }
    }

    private func styleBlock(_ block: Block, in storage: NSTextStorage, document: MarkdownDocument) {
        let r = block.range
        for key in Self.managedKeys { storage.removeAttribute(key, range: r) }

        var markerWidth: CGFloat = 0
        if case .bulletItem = block.kind, let m = block.markerRanges.first { markerWidth = width(of: m, in: storage) }
        if case .orderedItem = block.kind, let m = block.markerRanges.first { markerWidth = width(of: m, in: storage) }
        if case .taskItem = block.kind, let m = block.markerRanges.first { markerWidth = width(of: m, in: storage) }
        let (font, paragraph, color) = base(for: block.kind, markerWidth: markerWidth)
        storage.setAttributes([.font: font, .paragraphStyle: paragraph, .foregroundColor: color], range: r)

        switch block.kind {
        case .heading, .blockquote:
            for m in block.markerRanges { marker(m, .line, block.range, storage) }
            if case .blockquote = block.kind { storage.addAttribute(.mdQuote, value: true, range: r) }
        case .fencedCode:
            storage.addAttribute(.mdCodeBlock, value: true, range: r)
            for m in block.markerRanges { marker(m, .line, block.range, storage) }
        case .horizontalRule:
            storage.addAttribute(.mdHorizontalRule, value: true, range: r)
            for m in block.markerRanges { marker(m, .line, block.range, storage) }
        case .bulletItem, .orderedItem, .taskItem:
            // List markers stay visible (dimmed): hiding them makes list editing fragile.
            for m in block.markerRanges { storage.addAttribute(.foregroundColor, value: theme.listMarkerColor, range: m) }
        case .paragraph, .blank, .table:
            break
        }

        let inlines = document.inlines(in: block)
        if let table = block.table {
            for cell in table.header.cells { addTrait(.bold, cell, storage) }
        }
        for inline in inlines { styleInline(inline, in: storage) }
        if case .table(let alignments) = block.kind, let table = block.table {
            styleTable(block, table, alignments, in: storage)
        }

        // An image alone on its line is drawn below the line with its source hidden.
        if case .paragraph = block.kind, inlines.count == 1, case .image(let source, let alt) = inlines[0].kind,
           NSEqualRanges(inlines[0].range, block.contentRange) {
            let info = ImageInfo(source: source, alt: alt, lineRange: block.range)
            if let spacing = imageSpacing(info) {
                storage.addAttribute(.mdImage, value: info, range: r)
                marker(inlines[0].range, .span, inlines[0].range, storage)
                let p = theme.paragraphStyle().mutableCopy() as! NSMutableParagraphStyle
                p.paragraphSpacing = spacing
                storage.addAttribute(.paragraphStyle, value: p, range: r)
            }
        }
    }

    // MARK: Tables

    /// Pipes and the delimiter row become `.line` markers (hidden while the caret is outside the
    /// table), and every separator pipe gets the width that lines its row up in columns. A table
    /// whose rows cannot fit the column shows as source instead: pipes visible and dimmed.
    private func styleTable(_ block: Block, _ table: TableLayout, _ alignments: [TableAlignment], in storage: NSTextStorage) {
        let (geometry, fits) = tableGeometry(table, alignments, storage)
        storage.addAttribute(.mdTable, value: TableInfo(alignments: alignments, fits: fits, width: geometry.width,
                                                        grid: geometry.grid), range: block.range)
        // Cells past the header's column count are not part of the grid.
        for row in table.body where row.cells.count > table.columns {
            for cell in row.cells[table.columns...] {
                storage.addAttribute(.foregroundColor, value: theme.markerColor, range: cell)
            }
        }
        guard fits else {
            for m in block.markerRanges { storage.addAttribute(.foregroundColor, value: theme.markerColor, range: m) }
            return
        }
        // Revealed with the header line: the same whole-table reveal as the block range (blocks
        // never overlap), but a range that stays put while body rows are edited.
        for m in block.markerRanges { marker(m, .line, table.header.line, storage) }
        if table.delimiter.line.length > 0 { storage.addAttribute(.mdTableDelimiter, value: true, range: table.delimiter.line) }
        for space in geometry.collapsed { marker(space, .line, table.header.line, storage) }
        for (pipe, width) in geometry.pipeWidths {
            storage.addAttribute(.mdPipeWidth, value: NSNumber(value: Double(width)), range: NSRange(location: pipe, length: 1))
        }
    }

    private func tableGeometry(_ table: TableLayout, _ alignments: [TableAlignment],
                               _ storage: NSTextStorage) -> (TableGeometry, fits: Bool) {
        let available = tableWidth().flatMap { $0 > 0 ? $0 : nil } ?? .greatestFiniteMagnitude
        tableRowCache.fonts = [theme.bodySize, theme.codeSize]
        let geometry = TableGeometry.compute(table, alignments, storage: storage, gutter: theme.tableGutter, cache: tableRowCache)
        return (geometry, geometry.rowWidths.allSatisfy { $0 <= available - 2 })
    }

    /// Restyles only the row of `block` that `edited` falls in, when that gives the same
    /// attributes as restyling the whole table: the edit stays inside one line and adds no line
    /// break, the rest of the table still carries one `TableInfo` with the same alignments, and
    /// `fits` does not change. Returns false (nothing changed) when the whole block must be
    /// restyled instead. The other rows' markers are re-marked only when their reveal range (the
    /// header line) moved; their pipe widths, collapsed leading whitespace and the `TableInfo`
    /// wait for `alignTables`.
    private func restyleTableRow(_ block: Block, edited: NSRange, in storage: NSTextStorage,
                                 document: MarkdownDocument) -> Bool {
        guard case .table(let alignments) = block.kind, let table = block.table else { return false }
        let ns = storage.string as NSString
        let editEnd = edited.location + edited.length
        guard edited.location >= block.range.location, editEnd <= block.range.location + block.range.length,
              ns.rangeOfCharacter(from: .newlines, options: [], range: edited).location == NSNotFound else { return false }
        let rows = [table.header, table.delimiter] + table.body
        guard let index = rows.firstIndex(where: { edited.location >= $0.line.location && editEnd <= $0.line.location + $0.line.length })
        else { return false }
        let row = rows[index]
        // The row with its line terminator, clipped to the block.
        let full = NSIntersectionRange(ns.lineRange(for: row.line), block.range)

        // Everything else in the table must still be styled as this table: one TableInfo object.
        let before = NSRange(location: block.range.location, length: full.location - block.range.location)
        let after = NSRange(location: full.location + full.length, length: block.range.location + block.range.length - full.location - full.length)
        var old: TableInfo?
        for part in [before, after] where part.length > 0 {
            var run = NSRange()
            guard let info = storage.attribute(.mdTable, at: part.location, longestEffectiveRange: &run, in: part) as? TableInfo,
                  NSEqualRanges(run, part), old == nil || old === info else { return false }
            old = info
        }
        guard let old, old.alignments == alignments else { return false }

        // The row as styleBlock would style it.
        for key in Self.managedKeys { storage.removeAttribute(key, range: full) }
        let (font, paragraph, color) = base(for: block.kind, markerWidth: 0)
        storage.setAttributes([.font: font, .paragraphStyle: paragraph, .foregroundColor: color], range: full)
        if index == 0 { for cell in row.cells { addTrait(.bold, cell, storage) } }
        if index != 1 { for inline in document.inlines(in: row) { styleInline(inline, in: storage) } }

        let (geometry, fits) = tableGeometry(table, alignments, storage)
        guard fits == old.fits else {
            styleBlock(block, in: storage, document: document)
            return true
        }
        storage.addAttribute(.mdTable, value: old, range: full)
        if geometry.grid != old.grid { old.pendingAlign = true }
        if index >= 2, row.cells.count > table.columns {
            for cell in row.cells[table.columns...] { storage.addAttribute(.foregroundColor, value: theme.markerColor, range: cell) }
        }
        let rowMarkers = markers(of: block, in: full)
        guard fits else {
            for m in rowMarkers { storage.addAttribute(.foregroundColor, value: theme.markerColor, range: m) }
            return true
        }
        for m in rowMarkers { marker(m, .line, table.header.line, storage) }
        for space in geometry.collapsed where NSIntersectionRange(space, full).length > 0 {
            marker(space, .line, table.header.line, storage)
        }
        if index == 1, table.delimiter.line.length > 0 {
            storage.addAttribute(.mdTableDelimiter, value: true, range: table.delimiter.line)
        }
        // Only this row's pipes. When the edit moved the grid (old.grid differs), the other rows
        // keep their widths until `alignTables` runs: they are not used while the table is
        // revealed, and rewriting them re-lays out the whole table on every keystroke.
        for (pipe, width) in geometry.pipeWidths where NSLocationInRange(pipe, full) {
            storage.addAttribute(.mdPipeWidth, value: NSNumber(value: Double(width)), range: NSRange(location: pipe, length: 1))
        }
        return true
    }

    /// Brings every table intersecting `range`, other than those in `revealed` (block ranges whose
    /// pipes are shown), up to date with its grid: a row restyle (`style(..., edited:)`) leaves
    /// the other rows' pipe widths and the table's `TableInfo` as they were when the edit moved
    /// the grid. Call it once those tables are hidden. A table already in step costs one cached
    /// geometry pass.
    public func alignTables(_ storage: NSTextStorage, document: MarkdownDocument, in range: NSRange, revealed: [NSRange] = []) {
        guard storage.length == document.length, let indexes = document.blockIndexes(intersecting: range) else { return }
        for i in indexes {
            let block = document.blocks[i]
            guard case .table(let alignments) = block.kind, let table = block.table,
                  !revealed.contains(where: { NSEqualRanges($0, block.range) }) else { continue }
            let info = storage.attribute(.mdTable, at: block.range.location, effectiveRange: nil) as? TableInfo
            let (geometry, fits) = tableGeometry(table, alignments, storage)
            guard let info, info.fits == fits, info.alignments == alignments else {
                storage.beginEditing()
                styleBlock(block, in: storage, document: document)
                storage.endEditing()
                continue
            }
            guard info.grid != geometry.grid || info.pendingAlign else { continue }
            storage.beginEditing()
            storage.addAttribute(.mdTable, value: TableInfo(alignments: alignments, fits: fits, width: geometry.width,
                                                            grid: geometry.grid), range: block.range)
            if fits {
                // Which leading whitespace collapses follows the grid too.
                for space in geometry.collapsible {
                    storage.removeAttribute(.mdMarker, range: space)
                    storage.addAttribute(.foregroundColor, value: theme.textColor, range: space)
                }
                for space in geometry.collapsed { marker(space, .line, table.header.line, storage) }
                for (pipe, width) in geometry.pipeWidths {
                    storage.addAttribute(.mdPipeWidth, value: NSNumber(value: Double(width)), range: NSRange(location: pipe, length: 1))
                }
            }
            storage.endEditing()
        }
    }

    /// The block's marker ranges inside `range` (marker ranges are in text order).
    private func markers(of block: Block, in range: NSRange) -> ArraySlice<NSRange> {
        let all = block.markerRanges
        var lo = 0, hi = all.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if all[mid].location + all[mid].length <= range.location { lo = mid + 1 } else { hi = mid }
        }
        var end = lo
        while end < all.count, all[end].location < range.location + range.length { end += 1 }
        return all[lo..<end]
    }

    private func width(of range: NSRange, in storage: NSTextStorage) -> CGFloat {
        let text = (storage.string as NSString).substring(with: range).replacingOccurrences(of: "\t", with: "    ")
        return ceil((text as NSString).size(withAttributes: [.font: theme.bodyFont]).width)
    }

    private func marker(_ range: NSRange, _ scope: MarkerReveal.Scope, _ revealRange: NSRange, _ storage: NSTextStorage) {
        guard range.length > 0 else { return }
        if scope == .line {
            storage.addAttribute(.mdMarker, value: MarkerReveal(.line, revealRange, at: range.location), range: range)
        } else {
            for i in range.location..<(range.location + range.length) {
                storage.addAttribute(.mdMarker, value: MarkerReveal(.span, revealRange, at: i), range: NSRange(location: i, length: 1))
            }
        }
        storage.addAttribute(.foregroundColor, value: theme.markerColor, range: range)
    }

    // MARK: Inlines

    private func styleInline(_ inline: Inline, in storage: NSTextStorage) {
        let content = inline.contentRange
        switch inline.kind {
        case .strong: addTrait(.bold, content, storage)
        case .emphasis: addTrait(.italic, content, storage)
        case .strikethrough:
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: content)
        case .code:
            storage.enumerateAttribute(.font, in: inline.range) { value, run, _ in
                let size = ((value as? NSFont)?.pointSize ?? theme.bodySize) * theme.codeSize / theme.bodySize
                storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: size, weight: .regular), range: run)
            }
            storage.addAttribute(.backgroundColor, value: theme.codeBackground, range: inline.range)
        case .link(let url):
            storage.addAttribute(.foregroundColor, value: theme.linkColor, range: content)
            storage.addAttribute(.mdLinkURL, value: url, range: content)
        case .image:
            storage.addAttribute(.foregroundColor, value: theme.quoteColor, range: content)
        case .escape:
            break
        }
        for m in inline.markerRanges { marker(m, .span, inline.range, storage) }
        for child in inline.children { styleInline(child, in: storage) }
    }

    private func addTrait(_ trait: NSFontDescriptor.SymbolicTraits, _ range: NSRange, _ storage: NSTextStorage) {
        guard range.length > 0 else { return }
        storage.enumerateAttribute(.font, in: range) { value, run, _ in
            guard let font = value as? NSFont else { return }
            let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait))
            let converted = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
            storage.addAttribute(.font, value: converted, range: run)
        }
    }
}
