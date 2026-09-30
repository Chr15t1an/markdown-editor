import Foundation

/// One text replacement plus the selection to set afterwards.
public struct TextEdit: Equatable, Sendable {
    public var replacementRange: NSRange
    public var replacement: String
    public var newSelection: NSRange

    public init(_ range: NSRange, _ replacement: String, selection: NSRange) {
        replacementRange = range
        self.replacement = replacement
        newSelection = selection
    }

    /// The text after applying the edit (tests).
    public func applied(to text: String) -> String {
        (text as NSString).replacingCharacters(in: replacementRange, with: replacement)
    }
}

/// Formatting and structural edits as pure functions of (text, selection). `nil` means "let the
/// text view do its default thing".
public enum EditCommands {
    // MARK: Inline wraps

    /// Wraps the selection in `marker` (`**`, `*`, `` ` ``, `~~`), or unwraps it when it is
    /// already wrapped. With no selection, inserts the pair and puts the caret between.
    public static func toggleWrap(_ text: String, _ sel: NSRange, marker: String) -> TextEdit {
        let ns = text as NSString
        let m = (marker as NSString).length
        let markerChar = (marker as NSString).character(at: 0)

        // Markers just outside the selection: `**|sel|**`.
        let before = run(ns, of: markerChar, endingAt: sel.location)
        let after = run(ns, of: markerChar, startingAt: sel.location + sel.length)
        if matches(before, m), matches(after, m) {
            let range = NSRange(location: sel.location - m, length: sel.length + 2 * m)
            return TextEdit(range, ns.substring(with: sel), selection: NSRange(location: sel.location - m, length: sel.length))
        }
        // Markers just inside the selection: `|**sel**|`.
        if sel.length >= 2 * m {
            let inner = ns.substring(with: sel)
            if inner.hasPrefix(marker), inner.hasSuffix(marker) {
                let stripped = (inner as NSString).substring(with: NSRange(location: m, length: sel.length - 2 * m))
                return TextEdit(sel, stripped, selection: NSRange(location: sel.location, length: sel.length - 2 * m))
            }
        }
        let inner = ns.substring(with: sel)
        return TextEdit(sel, marker + inner + marker, selection: NSRange(location: sel.location + m, length: sel.length))
    }

    /// A run of `m` markers, or of `m + 2` (the marker next to another pair, as in `***x***`).
    private static func matches(_ runLength: Int, _ m: Int) -> Bool {
        runLength == m || (m <= 2 && runLength == 3)
    }

    private static func run(_ ns: NSString, of c: unichar, endingAt end: Int) -> Int {
        var i = end
        while i > 0, ns.character(at: i - 1) == c { i -= 1 }
        return end - i
    }

    private static func run(_ ns: NSString, of c: unichar, startingAt start: Int) -> Int {
        var i = start
        while i < ns.length, ns.character(at: i) == c { i += 1 }
        return i - start
    }

    /// `[selection](|)` — caret in the destination; with no selection `[|]()`.
    public static func makeLink(_ text: String, _ sel: NSRange) -> TextEdit {
        let inner = (text as NSString).substring(with: sel)
        if sel.length == 0 {
            return TextEdit(sel, "[]()", selection: NSRange(location: sel.location + 1, length: 0))
        }
        let replacement = "[\(inner)]()"
        return TextEdit(sel, replacement, selection: NSRange(location: sel.location + (replacement as NSString).length - 1, length: 0))
    }

    // MARK: Blocks

    /// Sets the caret line's heading level (0 = plain paragraph), replacing any existing `#`s.
    public static func setHeading(_ text: String, _ sel: NSRange, level: Int) -> TextEdit {
        let ns = text as NSString
        let line = lineContentRange(ns, at: sel.location)
        // Existing prefix: up to 3 spaces, 1-6 #, spaces.
        var p = line.location
        let end = line.location + line.length
        while p < end, p - line.location < 3, ns.character(at: p) == 0x20 { p += 1 }
        var q = p
        while q < end, ns.character(at: q) == 0x23 { q += 1 }
        var prefixEnd = line.location
        if q > p, q - p <= 6, q == end || ns.character(at: q) == 0x20 {
            prefixEnd = q
            while prefixEnd < end, ns.character(at: prefixEnd) == 0x20 { prefixEnd += 1 }
        }
        let oldPrefix = NSRange(location: line.location, length: prefixEnd - line.location)
        let newPrefix = level > 0 ? String(repeating: "#", count: min(6, level)) + " " : ""
        let delta = (newPrefix as NSString).length - oldPrefix.length
        func shift(_ loc: Int) -> Int { loc < prefixEnd ? line.location + (newPrefix as NSString).length : loc + delta }
        let newStart = shift(sel.location)
        let newEnd = shift(sel.location + sel.length)
        return TextEdit(oldPrefix, newPrefix, selection: NSRange(location: newStart, length: max(0, newEnd - newStart)))
    }

    /// Return inside a list item, task or quote continues it; on an empty item it removes the
    /// marker (ends the list). Inside fenced code, and everywhere else, the default applies.
    public static func newline(_ text: String, _ sel: NSRange) -> TextEdit? {
        guard sel.length == 0 else { return nil }
        let doc = MarkdownDocument(text)
        guard let index = doc.blockIndex(containing: sel.location) else { return nil }
        let block = doc.blocks[index]
        guard let marker = block.markerRanges.first else { return nil }
        let ns = text as NSString
        let markerEnd = marker.location + marker.length
        guard sel.location >= markerEnd else { return nil }

        let prefix: String
        switch block.kind {
        case .bulletItem, .taskItem, .orderedItem, .blockquote:
            let markerText = ns.substring(with: marker)
            prefix = continuation(of: markerText, kind: block.kind)
        default:
            return nil
        }

        let content = ns.substring(with: block.contentRange).trimmingCharacters(in: .whitespaces)
        if content.isEmpty {
            // Empty item: drop the marker and leave an empty line — the list ends here.
            let line = NSRange(location: block.range.location, length: block.contentRange.location + block.contentRange.length - block.range.location)
            return TextEdit(line, "", selection: NSRange(location: block.range.location, length: 0))
        }
        let insert = "\n" + prefix
        return TextEdit(sel, insert, selection: NSRange(location: sel.location + (insert as NSString).length, length: 0))
    }

    /// The marker for the next item: same indentation and bullet, ordered number + 1, task box
    /// unchecked, quote `> `.
    private static func continuation(of marker: String, kind: BlockKind) -> String {
        let indent = String(marker.prefix { $0 == " " || $0 == "\t" })
        let rest = marker.dropFirst(indent.count)
        switch kind {
        case .taskItem:
            return indent + String(rest.prefix(1)) + " [ ] "
        case .orderedItem:
            let digits = rest.prefix { $0.isNumber }
            let delimiter = rest.dropFirst(digits.count).prefix(1)
            let next = (Int(digits) ?? 0) + 1
            return indent + "\(next)" + delimiter + " "
        case .blockquote:
            return indent + "> "
        default:
            return indent + String(rest.prefix(1)) + " "
        }
    }

    /// Tab: indents list items on the selected lines by two spaces. `nil` outside lists.
    public static func indent(_ text: String, _ sel: NSRange) -> TextEdit? {
        shiftListLines(text, sel) { line, ns in (NSRange(location: line.location, length: 0), "  ") }
    }

    /// Shift-Tab: outdents list items on the selected lines by up to two spaces (or one tab).
    public static func outdent(_ text: String, _ sel: NSRange) -> TextEdit? {
        shiftListLines(text, sel) { line, ns in
            var n = 0
            while n < 2, line.location + n < ns.length, ns.character(at: line.location + n) == 0x20 { n += 1 }
            if n == 0, line.location < ns.length, ns.character(at: line.location) == 0x09 { n = 1 }
            return (NSRange(location: line.location, length: n), "")
        }
    }

    private static func shiftListLines(_ text: String, _ sel: NSRange,
                                       _ change: (NSRange, NSString) -> (NSRange, String)) -> TextEdit? {
        let doc = MarkdownDocument(text)
        guard let indexes = doc.blockIndexes(intersecting: sel) else { return nil }
        let blocks = indexes.map { doc.blocks[$0] }
        let isList: (Block) -> Bool = {
            switch $0.kind {
            case .bulletItem, .orderedItem, .taskItem: return true
            default: return false
            }
        }
        guard !blocks.isEmpty, blocks.allSatisfy(isList) else { return nil }
        let ns = text as NSString
        let whole = NSUnionRange(blocks.first!.range, blocks.last!.range)
        let changes = blocks.map { change($0.range, ns) }
        var result = ""
        var cursor = whole.location
        for (range, replacement) in changes {
            result += ns.substring(with: NSRange(location: cursor, length: range.location - cursor)) + replacement
            cursor = range.location + range.length
        }
        result += ns.substring(with: NSRange(location: cursor, length: whole.location + whole.length - cursor))
        guard result != ns.substring(with: whole) else { return nil }

        // Map a position through the changes (a position inside removed text moves to its start).
        func map(_ pos: Int) -> Int {
            var p = pos
            for (range, replacement) in changes {
                let added = (replacement as NSString).length
                if range.location + range.length <= pos { p += added - range.length }
                else if range.location < pos { p -= pos - range.location }
            }
            return p
        }
        let start = map(sel.location), end = map(sel.location + sel.length)
        return TextEdit(whole, result, selection: NSRange(location: start, length: max(0, end - start)))
    }

    private static func lineContentRange(_ ns: NSString, at location: Int) -> NSRange {
        var start = 0, contentsEnd = 0, end = 0
        ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: min(location, ns.length), length: 0))
        return NSRange(location: start, length: contentsEnd - start)
    }
}
