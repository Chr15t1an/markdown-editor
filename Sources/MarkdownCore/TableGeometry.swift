import AppKit

/// Column layout for a table shown with hidden pipes: each separator pipe becomes blank space
/// wide enough that the cell after it starts at its column's x on every row. Widths are measured
/// from the styled text (bold header, code cells), counting only what is visible while the caret
/// is outside the table (inline markers such as `**` and backticks are hidden then).
///
/// x positions are relative to the start of a row's line. Column c's content box starts at
/// `columnStarts[c]` and is as wide as the column's widest cell; a gutter sits on each side of
/// every column boundary. Right- and center-aligned cells are shifted inside their box by
/// widening the pipe before them; the pipe after the last cell pads the row to the right edge.
struct TableGeometry {
    /// Character index of a separator pipe → the width it takes while hidden.
    var pipeWidths: [Int: CGFloat] = [:]
    /// Where each laid-out row (header, then body) ends.
    var rowWidths: [CGFloat] = []
    var columnStarts: [CGFloat] = []
    /// The grid's right edge.
    var width: CGFloat = 0
    /// Whitespace hidden with the pipes (zero width): in a table mixing rows with and without a
    /// leading pipe, the indent and the space after a leading pipe, when column 0 starts left of them.
    var collapsed: [NSRange] = []
    /// Every row's leading whitespace that `collapsed` may hide (rows with a leading pipe).
    var collapsible: [NSRange] = []
    /// Column starts then column widths: with the rows, these decide every pipe width and
    /// which leading whitespace collapses.
    var grid: [CGFloat] = []

    /// One row split into the pieces that stay visible around its pipes.
    private struct Row {
        var leadingPipe: Int?
        /// Width before the leading pipe (indentation); 0 without one.
        var indent: CGFloat
        /// With a leading pipe: the indent and the whitespace between the pipe and the first cell.
        var leadingSpace: [NSRange]
        /// Per cell: whitespace before the text (after the previous pipe), the text, whitespace after.
        var cells: [(lead: CGFloat, text: CGFloat, trail: CGFloat, pipeAfter: Int?)]
    }

    static func compute(_ table: TableLayout, _ alignments: [TableAlignment], storage: NSTextStorage,
                        gutter: CGFloat, cache: TableRowCache? = nil) -> TableGeometry {
        let text = storage.string as NSString
        let rows = ([table.header] + table.body).enumerated().map { i, row in
            split(row, storage, measured: cache?.widths(text.substring(with: row.line) as NSString, header: i == 0) {
                measure(row, storage)
            } ?? measure(row, storage))
        }
        let columns = table.columns
        var g = TableGeometry()

        var columnWidths = [CGFloat](repeating: 0, count: columns)
        for row in rows {
            for (c, cell) in row.cells.prefix(columns).enumerated() { columnWidths[c] = max(columnWidths[c], cell.text) }
        }
        // Column 0 starts one gutter in; a row without a leading pipe has nothing to pad with, so
        // when one exists the column starts where the latest such row's text starts (rows with a
        // leading pipe then hide their leading whitespace if it would push the text past that).
        let natural = rows.map { row in row.indent + (row.cells.first?.lead ?? 0) }
        let unpaddable = zip(rows, natural).filter { $0.0.leadingPipe == nil }.map(\.1)
        var x = unpaddable.isEmpty ? max(gutter, natural.max() ?? 0) : (unpaddable.max() ?? 0)
        for w in columnWidths {
            g.columnStarts.append(x)
            x += w + 2 * gutter
        }
        g.width = (g.columnStarts.last ?? 0) + (columnWidths.last ?? 0) + gutter
        g.grid = g.columnStarts + columnWidths

        func shift(_ c: Int, _ text: CGFloat) -> CGFloat {
            let slack = max(0, columnWidths[c] - text)
            switch alignments[c] {
            case .right: return slack
            case .center: return (slack / 2).rounded(.down)
            case .left, .none: return 0
            }
        }

        for row in rows {
            g.collapsible += row.leadingSpace
            var pen = row.indent
            var firstLead = row.cells.first?.lead ?? 0
            if let pipe = row.leadingPipe, let first = row.cells.first {
                let target = g.columnStarts[0] + shift(0, first.text)
                if target < first.lead + pen {
                    g.collapsed += row.leadingSpace
                    pen = 0
                    firstLead = 0
                }
                let w = max(0, target - firstLead - pen)
                g.pipeWidths[pipe] = w
                pen += w
            }
            for (c, cell) in row.cells.enumerated() {
                pen += (c == 0 ? firstLead : cell.lead) + cell.text + cell.trail
                guard let pipe = cell.pipeAfter else { continue }
                let w: CGFloat
                if c + 1 < columns, c + 1 < row.cells.count {
                    let next = row.cells[c + 1]
                    w = max(0, g.columnStarts[c + 1] + shift(c + 1, next.text) - next.lead - pen)
                } else if c < columns {
                    w = max(0, g.width - pen)   // last column, or a short row: pad to the right edge
                } else {
                    w = gutter                  // between cells past the last column
                }
                g.pipeWidths[pipe] = w
                pen += w
            }
            g.rowWidths.append(pen)
        }
        return g
    }

    /// Where a row's pipes are: the leading one (if any), and per cell the pipes around it.
    private static func pipes(_ row: TableRow) -> (leading: Int?, around: [(before: Int?, after: Int?)]) {
        let hasLeading = !row.pipes.isEmpty && (row.cells.first.map { row.pipes[0] < $0.location } ?? true)
        let around = row.cells.indices.map { i -> (before: Int?, after: Int?) in
            let before = hasLeading ? row.pipes[i] : (i > 0 ? row.pipes[i - 1] : nil)
            let afterIndex = hasLeading ? i + 1 : i
            return (before, afterIndex < row.pipes.count ? row.pipes[afterIndex] : nil)
        }
        return (hasLeading ? row.pipes[0] : nil, around)
    }

    /// The visible widths in a row. They depend only on the row's own styled text (pipes are
    /// never inside a measured range), which is what lets `TableRowCache` key them by the text.
    private static func measure(_ row: TableRow, _ storage: NSTextStorage) -> TableRowCache.Widths {
        let lineEnd = row.line.location + row.line.length
        let (leading, around) = pipes(row)
        let indent = leading.map { visibleWidth(NSRange(location: row.line.location, length: $0 - row.line.location), storage) } ?? 0
        var cells: [TableRowCache.CellWidths] = []
        for (cell, (before, after)) in zip(row.cells, around) {
            let start = before.map { $0 + 1 } ?? row.line.location
            let end = after ?? lineEnd
            let cellEnd = cell.location + cell.length
            cells.append(TableRowCache.CellWidths(
                lead: visibleWidth(NSRange(location: start, length: cell.location - start), storage),
                text: visibleWidth(cell, storage),
                trail: visibleWidth(NSRange(location: cellEnd, length: max(0, end - cellEnd)), storage)))
        }
        return TableRowCache.Widths(indent: indent, cells: cells)
    }

    private static func split(_ row: TableRow, _ storage: NSTextStorage, measured: TableRowCache.Widths) -> Row {
        let (leading, around) = pipes(row)
        let cells = zip(measured.cells, around).map { (lead: $0.lead, text: $0.text, trail: $0.trail, pipeAfter: $1.after) }
        // Positions, not widths: derived from the row each time, so the cache stays keyed by text.
        var leadingSpace: [NSRange] = []
        if let pipe = leading {
            leadingSpace.append(NSRange(location: row.line.location, length: pipe - row.line.location))
            let firstText = row.cells.first?.location ?? pipe + 1
            leadingSpace.append(NSRange(location: pipe + 1, length: max(0, firstText - pipe - 1)))
            leadingSpace.removeAll { $0.length == 0 }
        }
        return Row(leadingPipe: leading, indent: measured.indent, leadingSpace: leadingSpace, cells: cells)
    }

    /// Rendered width of `range` without its inline marker characters (hidden while the caret is
    /// outside). Collapsed leading whitespace (a `.line` marker) counts: a row must measure the
    /// same whether or not an earlier grid collapsed it, since widths are cached by row text and
    /// a full restyle measures before marking.
    static func visibleWidth(_ range: NSRange, _ storage: NSTextStorage) -> CGFloat {
        guard range.length > 0 else { return 0 }
        let visible = NSMutableAttributedString()
        storage.enumerateAttribute(.mdMarker, in: range) { value, run, _ in
            if (value as? MarkerReveal)?.scope != .span { visible.append(storage.attributedSubstring(from: run)) }
        }
        return visible.length == 0 ? 0 : visible.size().width
    }
}

/// Measured widths of table rows, keyed by the row's text, so a keystroke in a large table
/// re-measures only the row it changed (review S2). Two generations bound the size without
/// emptying it all at once: rows still in use are carried into the new generation.
final class TableRowCache: @unchecked Sendable {
    struct CellWidths { var lead, text, trail: CGFloat }
    struct Widths { var indent: CGFloat; var cells: [CellWidths] }

    /// NSString: literal UTF-16 equality and a cheap hash (Swift String hashes by canonical
    /// equivalence, which is slower and would merge differently-encoded rows).
    private struct Key: Hashable {
        var text: NSString
        var header: Bool
        func hash(into h: inout Hasher) { h.combine(text.hash); h.combine(header) }
        static func == (a: Key, b: Key) -> Bool { a.header == b.header && a.text.isEqual(b.text) }
    }

    /// Theme sizes the widths were measured with; a change empties the cache.
    var fonts: [CGFloat] = [] {
        didSet { if fonts != oldValue { current.removeAll(); previous.removeAll() } }
    }
    private var current: [Key: Widths] = [:]
    private var previous: [Key: Widths] = [:]
    private let generationSize: Int

    init(generationSize: Int = 20_000) { self.generationSize = generationSize }

    func widths(_ text: NSString, header: Bool, measure: () -> Widths) -> Widths {
        let key = Key(text: text, header: header)
        if let hit = current[key] { return hit }
        let value = previous[key] ?? measure()
        if current.count >= generationSize {
            previous = current
            current.removeAll(keepingCapacity: true)
        }
        current[key] = value
        return value
    }
}
