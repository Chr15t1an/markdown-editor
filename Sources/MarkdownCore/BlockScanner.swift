import Foundation

/// Line-based block scan over UTF-16 code units, so every range is usable on NSTextStorage as is.
public enum BlockScanner {
    public static func scan(_ text: String) -> [Block] { scan(Array(text.utf16)) }

    public static func scan(_ u: [UInt16]) -> [Block] {
        var blocks: [Block] = []
        var fence: (char: UInt16, length: Int, start: Int, openMarker: NSRange, language: String?)?
        var table: OpenTable?
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

            if var t = table {
                if let row = bodyRow(u, i, contentEnd, lineEnd) {
                    t.body.append(row)
                    t.end = lineEnd
                    table = t
                    continue
                }
                blocks.append(t.block)
                table = nil
            }

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
            let block = classify(u, i, contentEnd, lineEnd)
            // A delimiter row under a paragraph line turns that line into a table header (a table
            // interrupts a paragraph: only the line right above the delimiter row is the header).
            if case .paragraph = block.kind, lineEnd < n,
               let open = openTable(u, header: (i, contentEnd), delimiterStart: lineEnd) {
                table = open
                lineEnd = open.end
                continue
            }
            blocks.append(block)
        }
        if let t = table { blocks.append(t.block) }
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

    // MARK: Tables (GFM)

    /// A table being scanned: header and delimiter found, body rows accumulating.
    private struct OpenTable {
        var start: Int
        var end: Int
        var alignments: [TableAlignment]
        var header: TableRow
        var delimiter: TableRow
        var body: [TableRow]

        var block: Block {
            let layout = TableLayout(header: header, delimiter: delimiter, body: body)
            var markers: [NSRange] = header.pipes.map { NSRange(location: $0, length: 1) }
            markers.append(delimiter.line)
            for row in body { markers += row.pipes.map { NSRange(location: $0, length: 1) } }
            let last = body.last ?? delimiter
            return Block(kind: .table(alignments: alignments),
                         range: NSRange(location: start, length: end - start),
                         markerRanges: markers,
                         contentRange: NSRange(location: header.line.location,
                                               length: last.line.location + last.line.length - header.line.location),
                         table: layout)
        }
    }

    /// End of the line starting at `start`: (content end, end including the terminator).
    private static func lineBounds(_ u: [UInt16], _ start: Int) -> (contentEnd: Int, lineEnd: Int) {
        var contentEnd = start
        while contentEnd < u.count, u[contentEnd] != U.lf, u[contentEnd] != U.cr { contentEnd += 1 }
        var lineEnd = contentEnd
        if lineEnd < u.count {
            if u[lineEnd] == U.cr, lineEnd + 1 < u.count, u[lineEnd + 1] == U.lf { lineEnd += 2 } else { lineEnd += 1 }
        }
        return (contentEnd, lineEnd)
    }

    /// Indentation in columns (tab = 4) and the first non-blank position.
    private static func indent(_ u: [UInt16], _ start: Int, _ end: Int) -> (columns: Int, first: Int) {
        var p = start, columns = 0
        while p < end, u[p] == U.space || u[p] == U.tab { columns += u[p] == U.tab ? 4 : 1; p += 1 }
        return (columns, p)
    }

    /// Splits a line into cells the way cmark-gfm's `row_from_string` does: optional leading pipe,
    /// cells separated by unescaped pipes (`\|` stays in the cell; `\\` is an escaped backslash,
    /// so `\\|` splits), optional trailing pipe, cells trimmed. Nil when the line has no cells.
    static func splitRow(_ u: [UInt16], _ start: Int, _ end: Int) -> TableRow? {
        func isSpace(_ c: UInt16) -> Bool { c == U.space || c == U.tab }
        var p = indent(u, start, end).first
        var pipes: [Int] = []
        var cells: [NSRange] = []
        if p < end, u[p] == U.pipe { pipes.append(p); p += 1 }
        while true {
            let cellStart = p
            while p < end, u[p] != U.pipe {
                if u[p] == U.backslash, p + 1 < end, U.isASCIIPunctuation(u[p + 1]) { p += 2 } else { p += 1 }
            }
            let cellEnd = min(p, end)
            var a = cellStart, b = cellEnd
            while a < b, isSpace(u[a]) { a += 1 }
            while b > a, isSpace(u[b - 1]) { b -= 1 }
            let followedByPipe = p < end
            if followedByPipe || b > a { cells.append(NSRange(location: a, length: b - a)) }
            guard followedByPipe else { break }
            pipes.append(p)
            p += 1
        }
        guard !cells.isEmpty else { return nil }
        return TableRow(line: NSRange(location: start, length: end - start), pipes: pipes, cells: cells)
    }

    /// A header line plus the delimiter row below it, when they form a table.
    private static func openTable(_ u: [UInt16], header: (start: Int, end: Int), delimiterStart: Int) -> OpenTable? {
        // Cheapest rejection first (runs for every paragraph line): a delimiter row is only
        // spaces, tabs, pipes, colons and dashes, with at least one pipe or colon — dashes alone
        // are a setext underline or a rule in CommonMark, never a delimiter row.
        let (dEnd, dLineEnd) = lineBounds(u, delimiterStart)
        var hasPipeOrColon = false
        for p in delimiterStart..<dEnd {
            switch u[p] {
            case U.pipe, U.colon: hasPipeOrColon = true
            case U.dash, U.space, U.tab: break
            default: return nil
            }
        }
        guard hasPipeOrColon else { return nil }
        guard indent(u, header.start, header.end).columns <= 3 else { return nil }
        let (columns, first) = indent(u, delimiterStart, dEnd)
        guard columns <= 3, first < dEnd else { return nil }
        // Anything that is already another block wins: `- | -` is a list item.
        guard case .paragraph = classify(u, delimiterStart, dEnd, dLineEnd).kind else { return nil }
        guard let delimiter = splitRow(u, delimiterStart, dEnd) else { return nil }
        var alignments: [TableAlignment] = []
        for cell in delimiter.cells {
            guard let a = alignment(u, cell) else { return nil }
            alignments.append(a)
        }
        guard let headerRow = splitRow(u, header.start, header.end),
              headerRow.cells.count == delimiter.cells.count else { return nil }
        return OpenTable(start: header.start, end: dLineEnd, alignments: alignments,
                         header: headerRow, delimiter: delimiter, body: [])
    }

    /// `:?-+:?` → alignment; anything else is not a delimiter cell.
    private static func alignment(_ u: [UInt16], _ cell: NSRange) -> TableAlignment? {
        var a = cell.location, b = cell.location + cell.length
        guard b > a else { return nil }
        let left = u[a] == U.colon, right = b - 1 > a && u[b - 1] == U.colon
        if left { a += 1 }
        if right { b -= 1 }
        guard b > a, u[a..<b].allSatisfy({ $0 == U.dash }) else { return nil }
        switch (left, right) {
        case (true, true): return .center
        case (true, false): return .left
        case (false, true): return .right
        case (false, false): return TableAlignment.none   // not `.none`: that is Optional.none here
        }
    }

    /// The line as one more table row, or nil when it ends the table: a blank line, 4+ columns of
    /// indent (indented code), a fence, or any other block start (heading, rule, list item, quote).
    /// A line without pipes is a row (GFM Example 202).
    private static func bodyRow(_ u: [UInt16], _ start: Int, _ end: Int, _ lineEnd: Int) -> TableRow? {
        let (columns, first) = indent(u, start, end)
        guard first < end, columns <= 3 else { return nil }
        if fenceRun(u, start, end, closing: nil) != nil { return nil }
        guard case .paragraph = classify(u, start, end, lineEnd).kind else { return nil }
        return splitRow(u, start, end)
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
