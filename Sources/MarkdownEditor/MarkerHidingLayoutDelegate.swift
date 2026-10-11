import AppKit
import MarkdownCore

/// Hides markdown markers at the glyph level (TextKit 1). The characters stay in the text
/// storage, so caret, selection, find, copy and undo work on the raw markdown.
///
/// Hidden marker glyphs are generated as control characters laid out with zero advancement
/// (WWDC18 session 221's approach) — except a table's pipes, which are laid out as whitespace of
/// the width the styler computed (`.mdPipeWidth`), so the cells line up in columns. Plain `.null` glyphs were tried first: at the start of a
/// line they are attached to the previous line fragment, which puts the caret and block chrome
/// on the wrong line.
final class MarkerHidingLayoutDelegate: NSObject, NSLayoutManagerDelegate {
    /// The current selection; `.span` markers touching it are shown.
    var selection = NSRange(location: 0, length: 0)
    /// Ranges of the blocks the selection touches; `.line` markers in them are shown.
    var revealedBlocks: [NSRange] = []
    /// Set by the editor from its styler's theme.
    var theme = Theme()

    func isHidden(_ reveal: MarkerReveal, at charIndex: Int) -> Bool {
        !reveal.isRevealed(at: charIndex, selection: selection, blockRanges: revealedBlocks)
    }

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>,
                       font aFont: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = layoutManager.textStorage else { return 0 }
        let count = glyphRange.length
        var modified: [NSLayoutManager.GlyphProperty]?
        let length = storage.length
        for i in 0..<count {
            let ci = charIndexes[i]
            guard ci < length,
                  let reveal = storage.attribute(.mdMarker, at: ci, effectiveRange: nil) as? MarkerReveal,
                  isHidden(reveal, at: ci) else { continue }
            if modified == nil { modified = Array(UnsafeBufferPointer(start: props, count: count)) }
            modified![i] = .controlCharacter
        }
        guard var newProps = modified else { return 0 }
        newProps.withUnsafeMutableBufferPointer { buffer in
            layoutManager.setGlyphs(glyphs, properties: buffer.baseAddress!, characterIndexes: charIndexes,
                                    font: aFont, forGlyphRange: glyphRange)
        }
        return count
    }

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        guard let storage = layoutManager.textStorage, charIndex < storage.length,
              let reveal = storage.attribute(.mdMarker, at: charIndex, effectiveRange: nil) as? MarkerReveal,
              isHidden(reveal, at: charIndex) else { return action }
        // A table's separator pipe keeps a width (its column padding); `.whitespace` is the only
        // action for which the typesetter asks boundingBoxForControlGlyphAt (research spike C).
        if storage.attribute(.mdPipeWidth, at: charIndex, effectiveRange: nil) != nil { return .whitespace }
        return .zeroAdvancement
    }

    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int,
                       for textContainer: NSTextContainer, proposedLineFragment proposedRect: NSRect,
                       glyphPosition: NSPoint, characterIndex charIndex: Int) -> NSRect {
        var width: CGFloat = 0
        if let storage = layoutManager.textStorage, charIndex < storage.length,
           let value = storage.attribute(.mdPipeWidth, at: charIndex, effectiveRange: nil) as? NSNumber {
            width = CGFloat(value.doubleValue)
        }
        return NSRect(x: glyphPosition.x, y: glyphPosition.y, width: width, height: proposedRect.height)
    }

    /// A table's delimiter row (`|---|---|`) collapses to a thin strip while hidden, instead of a
    /// blank line between the header and the body. Only that row: an empty body row (`||`) is all
    /// hidden markers too, but keeps its height.
    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
                       baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard let storage = layoutManager.textStorage else { return false }
        let chars = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard chars.length > 0, chars.location < storage.length,
              storage.attribute(.mdTableDelimiter, at: chars.location, effectiveRange: nil) != nil,
              let reveal = storage.attribute(.mdMarker, at: chars.location, effectiveRange: nil) as? MarkerReveal,
              isHidden(reveal, at: chars.location) else { return false }
        let h = theme.tableDelimiterStripHeight
        lineFragmentRect.pointee.size.height = h
        lineFragmentUsedRect.pointee.size.height = min(lineFragmentUsedRect.pointee.height, h)
        baselineOffset.pointee = min(baselineOffset.pointee, h)
        return true
    }

    /// Whether the glyph for `charIndex` is currently hidden (tests and probes).
    static func isHiddenGlyph(_ layoutManager: NSLayoutManager, character charIndex: Int) -> Bool {
        let g = layoutManager.glyphIndexForCharacter(at: charIndex)
        let p = layoutManager.propertyForGlyph(at: g)
        return p == .null || p == .controlCharacter
    }
}
