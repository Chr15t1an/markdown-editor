import Foundation

/// A parsed snapshot of the editor text: blocks up front, inlines per block on demand (cached).
public struct MarkdownDocument {
    public let units: [UInt16]
    public let blocks: [Block]
    private let cache = InlineCache()

    public init(_ text: String) {
        let u = Array(text.utf16)
        units = u
        blocks = BlockScanner.scan(u)
    }

    public var length: Int { units.count }

    public func inlines(in block: Block) -> [Inline] {
        switch block.kind {
        case .fencedCode, .horizontalRule, .blank: return []
        default: break
        }
        if let hit = cache.values[block.range.location] { return hit }
        let result: [Inline]
        if let table = block.table {
            // Cells are split on pipes first, then parsed one by one (GFM): a `**` never spans cells.
            result = (table.header.cells + table.body.flatMap(\.cells)).flatMap {
                InlineScanner.scan(units, in: $0).map(unescapingCellPipes)
            }
        } else {
            result = InlineScanner.scan(units, in: block.contentRange)
        }
        cache.values[block.range.location] = result
        return result
    }

    /// Inlines of one table row, parsed cell by cell like `inlines(in:)` does for the whole table.
    public func inlines(in row: TableRow) -> [Inline] {
        row.cells.flatMap { InlineScanner.scan(units, in: $0).map(unescapingCellPipes) }
    }

    /// In a table cell GFM unescapes `\|` before inline parsing, so even inside a code span it
    /// shows as `|`. Code spans are opaque to the inline scanner, so each `\|` in one becomes an
    /// `.escape` child here (its backslash is then hidden like any other escape).
    private func unescapingCellPipes(_ inline: Inline) -> Inline {
        var inline = inline
        inline.children = inline.children.map(unescapingCellPipes)
        guard inline.kind == .code else { return inline }
        let c = inline.contentRange
        var i = c.location
        while i + 1 < c.location + c.length {
            if units[i] == U.backslash, units[i + 1] == U.pipe {
                inline.children.append(Inline(kind: .escape, range: NSRange(location: i, length: 2),
                                              markerRanges: [NSRange(location: i, length: 1)],
                                              contentRange: NSRange(location: i + 1, length: 1)))
                i += 2
            } else {
                i += 1
            }
        }
        return inline
    }

    /// The block holding `location`. A location at the end of a line (before its terminator)
    /// belongs to that line; the empty line after a trailing newline belongs to no block.
    public func blockIndex(containing location: Int) -> Int? {
        var lo = 0, hi = blocks.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = blocks[mid].range
            if location < r.location { hi = mid - 1 }
            else if location >= r.location + r.length { lo = mid + 1 }
            else { return mid }
        }
        // End of document without a trailing newline: the caret sits on the last line.
        if let last = blocks.last, location == last.range.location + last.range.length,
           location == units.count, let end = units.last, end != U.lf, end != U.cr {
            return blocks.count - 1
        }
        return nil
    }

    /// Indexes of the blocks intersecting `range` (a zero-length range counts as a caret).
    public func blockIndexes(intersecting range: NSRange) -> ClosedRange<Int>? {
        guard let first = blockIndex(containing: range.location) ?? nearestBlock(after: range.location) else { return nil }
        let endLoc = range.length == 0 ? range.location : range.location + range.length - 1
        let last = blockIndex(containing: endLoc) ?? first
        return first...max(first, last)
    }

    private func nearestBlock(after location: Int) -> Int? {
        blocks.firstIndex { $0.range.location >= location }
    }
}

private final class InlineCache: @unchecked Sendable {
    var values: [Int: [Inline]] = [:]
}
