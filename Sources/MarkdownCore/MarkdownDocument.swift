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
            result = (table.header.cells + table.body.flatMap(\.cells)).flatMap { InlineScanner.scan(units, in: $0) }
        } else {
            result = InlineScanner.scan(units, in: block.contentRange)
        }
        cache.values[block.range.location] = result
        return result
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
