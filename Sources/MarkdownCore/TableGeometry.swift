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

    /// One row split into the pieces that stay visible around its pipes.
    private struct Row {
        var leadingPipe: Int?
        /// Width before the leading pipe (indentation); 0 without one.
        var indent: CGFloat
        /// Per cell: whitespace before the text (after the previous pipe), the text, whitespace after.
        var cells: [(lead: CGFloat, text: CGFloat, trail: CGFloat, pipeAfter: Int?)]
    }

    static func compute(_ table: TableLayout, _ alignments: [TableAlignment], storage: NSTextStorage,
                        gutter: CGFloat) -> TableGeometry {
        let rows = ([table.header] + table.body).map { split($0, storage) }
        let columns = table.columns
        var g = TableGeometry()

        var columnWidths = [CGFloat](repeating: 0, count: columns)
        for row in rows {
            for (c, cell) in row.cells.prefix(columns).enumerated() { columnWidths[c] = max(columnWidths[c], cell.text) }
        }
        // Column 0 starts one gutter in; a row without a leading pipe has nothing to pad with, so
        // when one exists the column starts where the latest such row's text starts.
        let natural = rows.map { row in row.indent + (row.cells.first?.lead ?? 0) }
        let unpaddable = zip(rows, natural).filter { $0.0.leadingPipe == nil }.map(\.1)
        var x = unpaddable.isEmpty ? max(gutter, natural.max() ?? 0) : (unpaddable.max() ?? 0)
        for w in columnWidths {
            g.columnStarts.append(x)
            x += w + 2 * gutter
        }
        g.width = (g.columnStarts.last ?? 0) + (columnWidths.last ?? 0) + gutter

        func shift(_ c: Int, _ text: CGFloat) -> CGFloat {
            let slack = max(0, columnWidths[c] - text)
            switch alignments[c] {
            case .right: return slack
            case .center: return (slack / 2).rounded(.down)
            case .left, .none: return 0
            }
        }

        for row in rows {
            var pen = row.indent
            if let pipe = row.leadingPipe, let first = row.cells.first {
                let w = max(0, g.columnStarts[0] + shift(0, first.text) - first.lead - pen)
                g.pipeWidths[pipe] = w
                pen += w
            }
            for (c, cell) in row.cells.enumerated() {
                pen += cell.lead + cell.text + cell.trail
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

    private static func split(_ row: TableRow, _ storage: NSTextStorage) -> Row {
        let lineEnd = row.line.location + row.line.length
        let hasLeading = !row.pipes.isEmpty && (row.cells.first.map { row.pipes[0] < $0.location } ?? true)
        let leading = hasLeading ? row.pipes[0] : nil
        let indent = leading.map { visibleWidth(NSRange(location: row.line.location, length: $0 - row.line.location), storage) } ?? 0
        var cells: [(lead: CGFloat, text: CGFloat, trail: CGFloat, pipeAfter: Int?)] = []
        for (i, cell) in row.cells.enumerated() {
            let before = hasLeading ? row.pipes[i] : (i > 0 ? row.pipes[i - 1] : nil)
            let afterIndex = hasLeading ? i + 1 : i
            let after = afterIndex < row.pipes.count ? row.pipes[afterIndex] : nil
            let start = before.map { $0 + 1 } ?? row.line.location
            let end = after ?? lineEnd
            let cellEnd = cell.location + cell.length
            cells.append((
                lead: visibleWidth(NSRange(location: start, length: cell.location - start), storage),
                text: visibleWidth(cell, storage),
                trail: visibleWidth(NSRange(location: cellEnd, length: max(0, end - cellEnd)), storage),
                pipeAfter: after))
        }
        return Row(leadingPipe: leading, indent: indent, cells: cells)
    }

    /// Rendered width of `range` without its marker characters (hidden while the caret is outside).
    static func visibleWidth(_ range: NSRange, _ storage: NSTextStorage) -> CGFloat {
        guard range.length > 0 else { return 0 }
        let visible = NSMutableAttributedString()
        storage.enumerateAttribute(.mdMarker, in: range) { value, run, _ in
            if value == nil { visible.append(storage.attributedSubstring(from: run)) }
        }
        return visible.length == 0 ? 0 : visible.size().width
    }
}
