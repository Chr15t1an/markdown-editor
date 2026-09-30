import Foundation

/// Line-based block scan over UTF-16 code units, so every range is usable on NSTextStorage as is.
public enum BlockScanner {
    public static func scan(_ text: String) -> [Block] { scan(Array(text.utf16)) }

    public static func scan(_ u: [UInt16]) -> [Block] {
        var blocks: [Block] = []
        var fence: (char: UInt16, length: Int, start: Int, openMarker: NSRange, language: String?)?
        var i = 0
        let n = u.count
        while i < n {
            // One line: [i, contentEnd) plus terminator up to lineEnd.
            var contentEnd = i
            while contentEnd < n, u[contentEnd] != U.lf, u[contentEnd] != U.cr { contentEnd += 1 }
            var lineEnd = contentEnd
            if lineEnd < n {
                if u[lineEnd] == U.cr, lineEnd + 1 < n, u[lineEnd + 1] == U.lf { lineEnd += 2 } else { lineEnd += 1 }
            }
            defer { i = lineEnd }

            if let f = fence {
                if fenceRun(u, i, contentEnd, closing: (f.char, f.length)) != nil {
                    let bodyStart = f.openMarker.location + lineLength(u, f.openMarker)
                    blocks.append(Block(
                        kind: .fencedCode(language: f.language),
                        range: NSRange(location: f.start, length: lineEnd - f.start),
                        markerRanges: [f.openMarker, NSRange(location: i, length: contentEnd - i)],
                        contentRange: NSRange(location: bodyStart, length: max(0, i - bodyStart))))
                    fence = nil
                }
                continue
            }

            if let open = fenceRun(u, i, contentEnd, closing: nil) {
                fence = (open.char, open.length, i, NSRange(location: i, length: contentEnd - i), open.language)
                continue
            }
            blocks.append(classify(u, i, contentEnd, lineEnd))
        }
        if let f = fence {  // unclosed fence runs to the end of the document
            let bodyStart = f.openMarker.location + lineLength(u, f.openMarker)
            blocks.append(Block(
                kind: .fencedCode(language: f.language),
                range: NSRange(location: f.start, length: n - f.start),
                markerRanges: [f.openMarker],
                contentRange: NSRange(location: bodyStart, length: max(0, n - bodyStart))))
        }
        return blocks
    }

    /// Length of the line holding `marker`, terminator included.
    private static func lineLength(_ u: [UInt16], _ marker: NSRange) -> Int {
        var end = marker.location + marker.length
        if end < u.count {
            if u[end] == U.cr, end + 1 < u.count, u[end + 1] == U.lf { end += 2 } else { end += 1 }
        }
        return end - marker.location
    }

    /// A fence line: optional indent, then ``` or ~~~ (3+). For a closing fence the run must use
    /// the opening character, be at least as long, and have nothing after it but spaces.
    private static func fenceRun(_ u: [UInt16], _ start: Int, _ end: Int,
                                 closing: (UInt16, Int)?) -> (char: UInt16, length: Int, language: String?)? {
        var p = start
        while p < end, u[p] == U.space || u[p] == U.tab { p += 1 }
        guard p < end, u[p] == U.backtick || u[p] == U.tilde else { return nil }
        let c = u[p]
        var q = p
        while q < end, u[q] == c { q += 1 }
        let length = q - p
        guard length >= 3 else { return nil }
        if let (char, minimum) = closing {
            guard c == char, length >= minimum else { return nil }
            var r = q
            while r < end, u[r] == U.space || u[r] == U.tab { r += 1 }
            return r == end ? (c, length, nil) : nil
        }
        let info = Array(u[q..<end])
        if c == U.backtick, info.contains(U.backtick) { return nil }
        let word = String(decoding: info, as: UTF16.self).trimmingCharacters(in: .whitespaces)
            .split(separator: " ").first.map(String.init)
        return (c, length, word?.isEmpty == false ? word : nil)
    }

    private static func classify(_ u: [UInt16], _ start: Int, _ end: Int, _ lineEnd: Int) -> Block {
        let whole = NSRange(location: start, length: lineEnd - start)
        // Indentation in columns (tab = 4) and the first non-blank position.
        var p = start, columns = 0
        while p < end, u[p] == U.space || u[p] == U.tab { columns += u[p] == U.tab ? 4 : 1; p += 1 }
        if p == end {
            return Block(kind: .blank, range: whole, markerRanges: [], contentRange: NSRange(location: start, length: 0))
        }
        let c = u[p]

        // ATX heading: up to 3 spaces, 1-6 #, then space/tab or end of line.
        if columns <= 3, c == U.hash {
            var q = p
            while q < end, u[q] == U.hash { q += 1 }
            let level = q - p
            if level <= 6, q == end || u[q] == U.space || u[q] == U.tab {
                var r = q
                while r < end, u[r] == U.space || u[r] == U.tab { r += 1 }
                return Block(kind: .heading(level: level), range: whole,
                             markerRanges: [NSRange(location: start, length: r - start)],
                             contentRange: NSRange(location: r, length: end - r))
            }
        }

        // Horizontal rule: up to 3 spaces, 3+ of the same -, * or _, spaces allowed between.
        if columns <= 3, c == U.dash || c == U.star || c == U.underscore {
            var count = 0, q = p, ok = true
            while q < end {
                if u[q] == c { count += 1 } else if u[q] != U.space && u[q] != U.tab { ok = false; break }
                q += 1
            }
            if ok, count >= 3 {
                return Block(kind: .horizontalRule, range: whole,
                             markerRanges: [NSRange(location: start, length: end - start)],
                             contentRange: NSRange(location: end, length: 0))
            }
        }

        let depth = columns / 2

        // Bullet and task items: -, * or + followed by a space.
        if c == U.dash || c == U.star || c == U.plus, p + 1 < end, u[p + 1] == U.space || u[p + 1] == U.tab {
            let q = min(p + 2, end)
            // Task box: "[ ] ", "[x] ", "[X] " (or at end of line).
            if q + 3 <= end, u[q] == U.lbracket, u[q + 2] == U.rbracket,
               u[q + 1] == U.space || u[q + 1] == U.x || u[q + 1] == U.X,
               q + 3 == end || u[q + 3] == U.space {
                let checked = u[q + 1] != U.space
                let markerEnd = min(q + 4, end)
                return Block(kind: .taskItem(depth: depth, checked: checked), range: whole,
                             markerRanges: [NSRange(location: start, length: markerEnd - start)],
                             contentRange: NSRange(location: markerEnd, length: end - markerEnd))
            }
            return Block(kind: .bulletItem(depth: depth), range: whole,
                         markerRanges: [NSRange(location: start, length: q - start)],
                         contentRange: NSRange(location: q, length: end - q))
        }

        // Ordered item: 1-9 digits, . or ), then a space.
        if U.isDigit(c) {
            var q = p
            while q < end, U.isDigit(u[q]) { q += 1 }
            if q - p <= 9, q + 1 < end, u[q] == U.dot || u[q] == U.rparen,
               u[q + 1] == U.space || u[q + 1] == U.tab {
                let markerEnd = min(q + 2, end)
                return Block(kind: .orderedItem(depth: depth), range: whole,
                             markerRanges: [NSRange(location: start, length: markerEnd - start)],
                             contentRange: NSRange(location: markerEnd, length: end - markerEnd))
            }
        }

        // Blockquote: up to 3 spaces, >, optional space. One level; nested > stay content.
        if columns <= 3, c == U.gt {
            var q = p + 1
            if q < end, u[q] == U.space || u[q] == U.tab { q += 1 }
            return Block(kind: .blockquote, range: whole,
                         markerRanges: [NSRange(location: start, length: q - start)],
                         contentRange: NSRange(location: q, length: end - q))
        }

        return Block(kind: .paragraph, range: whole, markerRanges: [],
                     contentRange: NSRange(location: start, length: end - start))
    }
}
