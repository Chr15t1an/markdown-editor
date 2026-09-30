import Foundation

/// Inline parsing within one block's content range. Order of precedence: backslash escapes and
/// code spans (opaque), then links / images (bracket matching), then emphasis delimiter runs
/// (`*`, `_`, `~~`) resolved with a simplified CommonMark delimiter stack.
public enum InlineScanner {
    public static func scan(_ text: String, in range: NSRange? = nil) -> [Inline] {
        let u = Array(text.utf16)
        return scan(u, in: range ?? NSRange(location: 0, length: u.count))
    }

    public static func scan(_ u: [UInt16], in range: NSRange) -> [Inline] {
        var parser = Parser(u: u)
        return parser.parse(range.location, range.location + range.length)
    }

    private struct Delimiter {
        var char: UInt16
        var start: Int      // current run start (shrinks from the right when used as opener)
        var length: Int     // remaining unmatched length
        var canOpen: Bool
        var canClose: Bool
    }

    private struct Parser {
        let u: [UInt16]

        mutating func parse(_ start: Int, _ end: Int) -> [Inline] {
            var atoms: [Inline] = []
            var delimiters: [Delimiter] = []
            var i = start
            while i < end {
                let c = u[i]
                if c == U.backslash, i + 1 < end, U.isASCIIPunctuation(u[i + 1]) {
                    atoms.append(Inline(kind: .escape, range: NSRange(location: i, length: 2),
                                        markerRanges: [NSRange(location: i, length: 1)],
                                        contentRange: NSRange(location: i + 1, length: 1)))
                    i += 2
                } else if c == U.backtick {
                    let run = runLength(i, end, U.backtick)
                    if let code = codeSpan(i, run, end) {
                        atoms.append(code)
                        i = code.range.location + code.range.length
                    } else {
                        i += run
                    }
                } else if c == U.lbracket || (c == U.bang && i + 1 < end && u[i + 1] == U.lbracket) {
                    if let link = linkOrImage(i, end) {
                        atoms.append(link)
                        i = link.range.location + link.range.length
                    } else {
                        i += c == U.bang ? 2 : 1
                    }
                } else if c == U.star || c == U.underscore || c == U.tilde {
                    let run = runLength(i, end, c)
                    if c != U.tilde || run == 2 {
                        let before: UInt16? = i > 0 ? u[i - 1] : nil
                        let after: UInt16? = i + run < u.count ? u[i + run] : nil
                        var canOpen = after.map { !U.isWhitespace($0) } ?? false
                        var canClose = before.map { !U.isWhitespace($0) } ?? false
                        if i == start { canClose = false }
                        if i + run == end { canOpen = false }
                        if c == U.underscore {  // no intraword emphasis with _
                            if let b = before, U.isAlphanumeric(b) { canOpen = false }
                            if let a = after, U.isAlphanumeric(a) { canClose = false }
                        }
                        delimiters.append(Delimiter(char: c, start: i, length: run, canOpen: canOpen, canClose: canClose))
                    }
                    i += run
                } else {
                    i += 1
                }
            }
            let emphasis = resolve(&delimiters, atoms: atoms)
            return nest(atoms + emphasis)
        }

        private func runLength(_ i: Int, _ end: Int, _ c: UInt16) -> Int {
            var j = i
            while j < end, u[j] == c { j += 1 }
            return j - i
        }

        /// A backtick run of length `run` at `i`, closed by the next run of exactly that length.
        private func codeSpan(_ i: Int, _ run: Int, _ end: Int) -> Inline? {
            var j = i + run
            while j < end {
                if u[j] == U.backtick {
                    let r = runLength(j, end, U.backtick)
                    if r == run {
                        return Inline(kind: .code, range: NSRange(location: i, length: j + r - i),
                                      markerRanges: [NSRange(location: i, length: run), NSRange(location: j, length: r)],
                                      contentRange: NSRange(location: i + run, length: j - i - run))
                    }
                    j += r
                } else {
                    j += 1
                }
            }
            return nil
        }

        /// `[text](url)` or `![alt](src)` starting at `i`. Brackets nest; code spans and escapes
        /// inside the text are skipped. Destination: `<...>` or a run without spaces (balanced
        /// parentheses), optionally followed by a quoted title.
        private mutating func linkOrImage(_ i: Int, _ end: Int) -> Inline? {
            let isImage = u[i] == U.bang
            let open = isImage ? i + 1 : i
            var depth = 0
            var j = open
            var close = -1
            while j < end {
                let c = u[j]
                if c == U.backslash, j + 1 < end { j += 2; continue }
                if c == U.backtick {
                    let run = runLength(j, end, U.backtick)
                    if let code = codeSpan(j, run, end) { j = code.range.location + code.range.length } else { j += run }
                    continue
                }
                if c == U.lbracket { depth += 1 }
                if c == U.rbracket { depth -= 1; if depth == 0 { close = j; break } }
                j += 1
            }
            guard close > 0, close + 1 < end, u[close + 1] == U.lparen else { return nil }
            var k = close + 2
            while k < end, u[k] == U.space { k += 1 }
            let destStart: Int, destEnd: Int
            if k < end, u[k] == U.lt {
                var m = k + 1
                while m < end, u[m] != U.gt, u[m] != U.lf { m += 1 }
                guard m < end, u[m] == U.gt else { return nil }
                destStart = k + 1; destEnd = m; k = m + 1
            } else {
                var parens = 0
                var m = k
                while m < end {
                    let c = u[m]
                    if U.isWhitespace(c) { break }
                    if c == U.backslash, m + 1 < end { m += 2; continue }
                    if c == U.lparen { parens += 1 }
                    if c == U.rparen { if parens == 0 { break }; parens -= 1 }
                    m += 1
                }
                destStart = k; destEnd = m; k = m
            }
            while k < end, u[k] == U.space { k += 1 }
            if k < end, u[k] == U.quote || u[k] == U.apostrophe {  // optional title
                let q = u[k]
                var m = k + 1
                while m < end, u[m] != q { m += 1 }
                guard m < end else { return nil }
                k = m + 1
                while k < end, u[k] == U.space { k += 1 }
            }
            guard k < end, u[k] == U.rparen else { return nil }
            let url = String(decoding: u[destStart..<destEnd], as: UTF16.self)
            let content = NSRange(location: open + 1, length: close - open - 1)
            let full = NSRange(location: i, length: k + 1 - i)
            let markers = [NSRange(location: i, length: open + 1 - i), NSRange(location: close, length: k + 1 - close)]
            if isImage {
                let alt = String(decoding: u[content.location..<(content.location + content.length)], as: UTF16.self)
                return Inline(kind: .image(source: url, alt: alt), range: full, markerRanges: markers, contentRange: content)
            }
            let children = parse(content.location, content.location + content.length)
            return Inline(kind: .link(url: url), range: full, markerRanges: markers, contentRange: content, children: children)
        }

        /// Matches closers against earlier openers of the same character. Delimiters cannot pair
        /// across an atom (code span, link) boundary because atoms are opaque in the scan.
        private func resolve(_ delims: inout [Delimiter], atoms: [Inline]) -> [Inline] {
            var result: [Inline] = []
            var closerIndex = 0
            while closerIndex < delims.count {
                let closer = delims[closerIndex]
                guard closer.canClose, closer.length > 0 else { closerIndex += 1; continue }
                var openerIndex = closerIndex - 1
                var matched = false
                while openerIndex >= 0 {
                    let opener = delims[openerIndex]
                    if opener.char == closer.char, opener.canOpen, opener.length > 0,
                       !crossesAtom(opener.start + opener.length, closer.start, atoms) {
                        let use: Int
                        let kind: InlineKind
                        if closer.char == U.tilde {
                            use = 2; kind = .strikethrough
                        } else if opener.length >= 2 && closer.length >= 2 {
                            use = 2; kind = .strong
                        } else {
                            use = 1; kind = .emphasis
                        }
                        let openMarker = NSRange(location: opener.start + opener.length - use, length: use)
                        let closeMarker = NSRange(location: closer.start, length: use)
                        result.append(Inline(
                            kind: kind,
                            range: NSRange(location: openMarker.location, length: closeMarker.location + use - openMarker.location),
                            markerRanges: [openMarker, closeMarker],
                            contentRange: NSRange(location: openMarker.location + use,
                                                  length: closeMarker.location - openMarker.location - use)))
                        delims[openerIndex].length -= use
                        delims[closerIndex].start += use
                        delims[closerIndex].length -= use
                        // Openers between the pair can no longer match anything.
                        for k in (openerIndex + 1)..<closerIndex { delims[k].length = 0 }
                        matched = true
                        break
                    }
                    openerIndex -= 1
                }
                if !matched || delims[closerIndex].length == 0 { closerIndex += 1 }
            }
            return result
        }

        /// True when an atom straddles the boundary of [from, to) (starts inside and ends outside,
        /// or the reverse) — such a pair would split the atom.
        private func crossesAtom(_ from: Int, _ to: Int, _ atoms: [Inline]) -> Bool {
            for a in atoms {
                let s = a.range.location, e = a.range.location + a.range.length
                let startsInside = s >= from && s < to, endsInside = e > from && e <= to
                if startsInside != endsInside { return true }
            }
            return false
        }

        /// Builds the containment tree (outer spans first).
        private func nest(_ items: [Inline]) -> [Inline] {
            let sorted = items.sorted {
                $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.range.length > $1.range.length
            }
            var roots: [Inline] = []
            for item in sorted { insert(item, into: &roots) }
            return roots
        }

        private func insert(_ item: Inline, into list: inout [Inline]) {
            if let last = list.indices.last, contains(list[last].contentRange, item.range) {
                insert(item, into: &list[last].children)
                list[last].children.sort { $0.range.location < $1.range.location }
            } else {
                list.append(item)
            }
        }

        private func contains(_ outer: NSRange, _ inner: NSRange) -> Bool {
            inner.location >= outer.location && inner.location + inner.length <= outer.location + outer.length
        }
    }
}
