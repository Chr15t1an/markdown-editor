import Foundation

/// Block-level kinds. Each block is one line, except fenced code (fence open through close).
public enum BlockKind: Equatable, Sendable {
    case paragraph
    case heading(level: Int)
    case bulletItem(depth: Int)
    case orderedItem(depth: Int)
    case taskItem(depth: Int, checked: Bool)
    case blockquote
    case fencedCode(language: String?)
    case horizontalRule
    case blank
}

public struct Block: Equatable, Sendable {
    public var kind: BlockKind
    /// Whole line(s), including the line terminator.
    public var range: NSRange
    /// Syntax characters: "## ", "- ", "- [ ] ", "> ", fence lines, "---".
    public var markerRanges: [NSRange]
    /// The text inline parsing runs over (for fenced code: the code body; empty for hr/blank).
    public var contentRange: NSRange

    public init(kind: BlockKind, range: NSRange, markerRanges: [NSRange], contentRange: NSRange) {
        self.kind = kind
        self.range = range
        self.markerRanges = markerRanges
        self.contentRange = contentRange
    }
}

public enum InlineKind: Equatable, Sendable {
    case strong, emphasis, strikethrough, code
    case link(url: String)
    case image(source: String, alt: String)
    /// A backslash escape: the backslash is the marker, the escaped character the content.
    case escape
}

public struct Inline: Equatable, Sendable {
    public var kind: InlineKind
    /// Full span including markers.
    public var range: NSRange
    /// "**", "`", "[", "](url)", "![", "](src)", "\".
    public var markerRanges: [NSRange]
    public var contentRange: NSRange
    public var children: [Inline]

    public init(kind: InlineKind, range: NSRange, markerRanges: [NSRange], contentRange: NSRange, children: [Inline] = []) {
        self.kind = kind
        self.range = range
        self.markerRanges = markerRanges
        self.contentRange = contentRange
        self.children = children
    }
}

/// UTF-16 code units used by the scanners.
enum U {
    static let lf: UInt16 = 0x0A, cr: UInt16 = 0x0D, space: UInt16 = 0x20, tab: UInt16 = 0x09
    static let hash: UInt16 = 0x23, star: UInt16 = 0x2A, underscore: UInt16 = 0x5F, dash: UInt16 = 0x2D
    static let plus: UInt16 = 0x2B, gt: UInt16 = 0x3E, backtick: UInt16 = 0x60, tilde: UInt16 = 0x7E
    static let lbracket: UInt16 = 0x5B, rbracket: UInt16 = 0x5D, lparen: UInt16 = 0x28, rparen: UInt16 = 0x29
    static let bang: UInt16 = 0x21, backslash: UInt16 = 0x5C, dot: UInt16 = 0x2E, x: UInt16 = 0x78, X: UInt16 = 0x58
    static let lt: UInt16 = 0x3C, quote: UInt16 = 0x22, apostrophe: UInt16 = 0x27

    static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
    static func isWhitespace(_ c: UInt16) -> Bool { c == space || c == tab || c == lf || c == cr || c == 0xA0 }
    static func isASCIIPunctuation(_ c: UInt16) -> Bool {
        (c >= 0x21 && c <= 0x2F) || (c >= 0x3A && c <= 0x40) || (c >= 0x5B && c <= 0x60) || (c >= 0x7B && c <= 0x7E)
    }
    static func isAlphanumeric(_ c: UInt16) -> Bool {
        if c < 0x80 { return (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }
        guard let scalar = Unicode.Scalar(UInt32(c)) else { return true }  // surrogate halves: letters/emoji
        return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }
}
