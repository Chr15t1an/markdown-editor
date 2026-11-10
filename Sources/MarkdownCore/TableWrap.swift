import AppKit

/// Layout for a table whose rows do not fit the column on one line each: cells wrap inside
/// columns that together fit the column. While the caret is outside the table its whole source
/// is hidden, each row's line takes the height of its tallest wrapped cell, and the editor's
/// layout manager draws the cells (`cellString`) into the boxes this layout gives.
///
/// Column widths follow automatic table layout in browsers: every column gets at least its
/// longest word (min-content), and the room left is shared in proportion to how much wider each
/// column's widest cell is than that (max-content minus min-content). When even the longest
/// words do not fit, columns get the room in proportion to them and words break.
///
/// x positions are relative to the start of a row's line, as in `TableGeometry`.
public struct WrappedTable: Equatable, Sendable {
    public var columnStarts: [CGFloat]
    public var columnWidths: [CGFloat]
    /// The grid's right edge.
    public var width: CGFloat
    /// Header row, then body rows: line height including the vertical padding.
    public var rowHeights: [CGFloat]

    /// Nil when the columns cannot each get `minColumn` (the table then shows as source).
    static func compute(_ table: TableLayout, _ alignments: [TableAlignment], natural: [CGFloat],
                        storage: NSTextStorage, available: CGFloat, theme: Theme,
                        cache: TableRowCache?) -> WrappedTable? {
        let columns = table.columns
        let gutter = theme.tableGutter
        let budget = available - 2 * gutter * CGFloat(columns)
        guard columns > 0, natural.count == columns, budget >= theme.tableMinColumnWidth * CGFloat(columns) else { return nil }
        let text = storage.string as NSString
        let rows = [table.header] + table.body

        // Min-content: each column's longest word.
        var minimum = [CGFloat](repeating: 0, count: columns)
        for (i, row) in rows.enumerated() {
            let words = cache?.words(text.substring(with: row.line) as NSString, header: i == 0) {
                longestWords(row, columns, storage)
            } ?? longestWords(row, columns, storage)
            for (c, w) in words.prefix(columns).enumerated() { minimum[c] = max(minimum[c], w) }
        }
        let maximum = zip(natural, minimum).map { max($0, $1) }
        var widths: [CGFloat]
        let minTotal = minimum.reduce(0, +)
        if minTotal >= budget {
            let floor = theme.tableMinColumnWidth
            let spare = budget - floor * CGFloat(columns)
            widths = minimum.map { floor + (minTotal > 0 ? spare * $0 / minTotal : spare / CGFloat(columns)) }
        } else {
            let stretch = zip(maximum, minimum).map { $0 - $1 }
            let stretchTotal = stretch.reduce(0, +)
            let extra = budget - minTotal
            widths = zip(minimum, stretch).map { m, s in
                m + (stretchTotal > 0 ? min(s, extra * s / stretchTotal) : 0)
            }
        }
        widths = widths.map { $0.rounded(.down) }

        var starts: [CGFloat] = []
        var x = gutter
        for w in widths {
            starts.append(x)
            x += w + 2 * gutter
        }
        let width = (starts.last ?? 0) + (widths.last ?? 0) + gutter

        let padding = theme.tableWrappedRowPadding
        let single = lineHeight(theme)
        var heights: [CGFloat] = []
        for (i, row) in rows.enumerated() {
            let measure = { () -> CGFloat in
                var h = single
                for (c, cell) in row.cells.prefix(columns).enumerated() where cell.length > 0 {
                    h = max(h, height(cellString(cell, storage, alignment: alignments[c]), width: widths[c]))
                }
                return h
            }
            let h = cache?.height(text.substring(with: row.line) as NSString, header: i == 0, widths: widths, measure: measure)
                ?? measure()
            heights.append(h + 2 * padding)
        }
        return WrappedTable(columnStarts: starts, columnWidths: widths, width: width, rowHeights: heights)
    }

    /// The cell as drawn: its visible text (inline markers dropped, as while the caret is
    /// outside), aligned and wrapping by word.
    public static func cellString(_ cell: NSRange, _ storage: NSTextStorage, alignment: TableAlignment) -> NSAttributedString {
        let visible = NSMutableAttributedString()
        guard cell.length > 0 else { return visible }
        storage.enumerateAttribute(.mdMarker, in: cell) { value, run, _ in
            if (value as? MarkerReveal)?.scope != .span { visible.append(storage.attributedSubstring(from: run)) }
        }
        let all = NSRange(location: 0, length: visible.length)
        guard all.length > 0 else { return visible }
        visible.removeAttribute(.mdMarker, range: all)
        let base = (visible.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle) ?? .default
        let paragraph = base.mutableCopy() as! NSMutableParagraphStyle
        paragraph.firstLineHeadIndent = 0
        paragraph.headIndent = 0
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.paragraphSpacing = 0
        paragraph.paragraphSpacingBefore = 0
        switch alignment {
        case .left: paragraph.alignment = .left
        case .center: paragraph.alignment = .center
        case .right: paragraph.alignment = .right
        case .none: paragraph.alignment = .natural
        }
        visible.addAttribute(.paragraphStyle, value: paragraph, range: all)
        return visible
    }

    /// Options shared by measuring and drawing a cell, so a cell always fits its row.
    public static let drawingOptions: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    static func height(_ string: NSAttributedString, width: CGFloat) -> CGFloat {
        guard string.length > 0 else { return 0 }
        return ceil(string.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                        options: drawingOptions).height)
    }

    /// One body line's height, the floor for a row (an empty row keeps a line).
    static func lineHeight(_ theme: Theme) -> CGFloat {
        height(NSAttributedString(string: "X", attributes: theme.bodyAttributes), width: .greatestFiniteMagnitude)
    }

    /// Per cell, the width of its widest whitespace-separated word as drawn.
    private static func longestWords(_ row: TableRow, _ columns: Int, _ storage: NSTextStorage) -> [CGFloat] {
        row.cells.prefix(columns).map { cell in
            let s = cellString(cell, storage, alignment: .none)
            let ns = s.string as NSString
            var widest: CGFloat = 0
            var start = -1
            for i in 0...ns.length {
                let space = i == ns.length || CharacterSet.whitespaces.contains(UnicodeScalar(ns.character(at: i)) ?? " ")
                if space {
                    if start >= 0 {
                        widest = max(widest, ceil(s.attributedSubstring(from: NSRange(location: start, length: i - start)).size().width))
                        start = -1
                    }
                } else if start < 0 {
                    start = i
                }
            }
            return widest
        }
    }
}

extension BlockScanner {
    /// The rows of the table occupying `range` in `string` (header, delimiter, body), re-split
    /// from the text so the ranges are current wherever the table has moved.
    public static func tableRows(_ string: NSString, in range: NSRange) -> [TableRow] {
        let u = Array(string.substring(with: range).utf16)
        var rows: [TableRow] = []
        var i = 0
        while i < u.count {
            var end = i
            while end < u.count, u[end] != U.lf, u[end] != U.cr { end += 1 }
            let row = splitRow(u, i, end) ?? TableRow(line: NSRange(location: i, length: end - i), pipes: [], cells: [])
            rows.append(row.shifted(by: range.location))
            if end < u.count, u[end] == U.cr, end + 1 < u.count, u[end + 1] == U.lf { end += 1 }
            i = end + 1
        }
        return rows
    }
}
