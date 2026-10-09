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
public final class MarkerReveal: NSObject, @unchecked Sendable {
    public enum Scope: Equatable, Sendable { case span, line }
    public let scope: Scope
    public let range: NSRange

    public init(_ scope: Scope, _ range: NSRange) {
        self.scope = scope
        self.range = range
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? MarkerReveal else { return false }
        return scope == other.scope && NSEqualRanges(range, other.range)
    }

    public override var hash: Int { range.location &* 31 &+ range.length &+ (scope == .span ? 1 : 2) }

    /// Whether this marker is shown for `selection`, given the ranges of the blocks it touches.
    public func isRevealed(selection: NSRange, blockRanges: [NSRange]) -> Bool {
        switch scope {
        case .span:
            let end = range.location + range.length
            if selection.length == 0 { return selection.location >= range.location && selection.location <= end }
            return NSIntersectionRange(selection, range).length > 0
        case .line:
            return blockRanges.contains { NSIntersectionRange($0, range).length > 0 || NSEqualRanges($0, range) }
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

    public init(alignments: [TableAlignment], fits: Bool, width: CGFloat) {
        self.alignments = alignments
        self.fits = fits
        self.width = width
    }
    public override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? TableInfo else { return false }
        return o.alignments == alignments && o.fits == fits && o.width == width
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
    /// Space on each side of a column boundary.
    public static let tableGutter: CGFloat = 12

    public init(theme: Theme = Theme()) { self.theme = theme }

    private static let managedKeys: [NSAttributedString.Key] = [
        .mdMarker, .mdHorizontalRule, .mdQuote, .mdCodeBlock, .mdLinkURL, .mdImage, .mdTable, .mdPipeWidth, .mdTableDelimiter,
        .strikethroughStyle, .backgroundColor, .underlineStyle, .link, .kern,
    ]

    /// Restyles every block intersecting `range` (whole blocks). Returns the range styled.
    @discardableResult
    public func style(_ storage: NSTextStorage, document: MarkdownDocument, in range: NSRange) -> NSRange {
        guard storage.length == document.length else { return NSRange(location: 0, length: 0) }
        guard let indexes = document.blockIndexes(intersecting: range) else { return NSRange(location: 0, length: 0) }
        let first = document.blocks[indexes.lowerBound].range
        let last = document.blocks[indexes.upperBound].range
        let styled = NSUnionRange(first, last)
        storage.beginEditing()
        for i in indexes { styleBlock(document.blocks[i], in: storage, document: document) }
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
            let spacing: CGFloat = level <= 2 ? 10 : 6
            return (theme.headingFont(level: level), theme.paragraphStyle(spacingBefore: spacing, lineHeightMultiple: 1.15), theme.textColor)
        case .bulletItem, .orderedItem, .taskItem:
            return (theme.bodyFont, theme.paragraphStyle(headIndent: markerWidth), theme.textColor)
        case .blockquote:
            return (theme.bodyFont, theme.paragraphStyle(headIndent: theme.quoteIndent, firstLineHeadIndent: theme.quoteIndent), theme.quoteColor)
        case .fencedCode:
            return (theme.codeFont, theme.paragraphStyle(headIndent: 12, firstLineHeadIndent: 12, lineHeightMultiple: 1.2), theme.textColor)
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
        let available = tableWidth().flatMap { $0 > 0 ? $0 : nil } ?? .greatestFiniteMagnitude
        let geometry = TableGeometry.compute(table, alignments, storage: storage, gutter: Self.tableGutter)
        let fits = geometry.rowWidths.allSatisfy { $0 <= available - 2 }
        storage.addAttribute(.mdTable, value: TableInfo(alignments: alignments, fits: fits, width: geometry.width), range: block.range)
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
        for m in block.markerRanges { marker(m, .line, block.range, storage) }
        if table.delimiter.line.length > 0 { storage.addAttribute(.mdTableDelimiter, value: true, range: table.delimiter.line) }
        for (pipe, width) in geometry.pipeWidths {
            storage.addAttribute(.mdPipeWidth, value: NSNumber(value: Double(width)), range: NSRange(location: pipe, length: 1))
        }
    }

    private func width(of range: NSRange, in storage: NSTextStorage) -> CGFloat {
        let text = (storage.string as NSString).substring(with: range).replacingOccurrences(of: "\t", with: "    ")
        return ceil((text as NSString).size(withAttributes: [.font: theme.bodyFont]).width)
    }

    private func marker(_ range: NSRange, _ scope: MarkerReveal.Scope, _ revealRange: NSRange, _ storage: NSTextStorage) {
        guard range.length > 0 else { return }
        storage.addAttribute(.mdMarker, value: MarkerReveal(scope, revealRange), range: range)
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
