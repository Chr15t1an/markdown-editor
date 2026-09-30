import AppKit
import MarkdownCore

/// Hides markdown markers at the glyph level (TextKit 1). The characters stay in the text
/// storage, so caret, selection, find, copy and undo work on the raw markdown.
///
/// Hidden marker glyphs are generated as control characters laid out with zero advancement
/// (WWDC18 session 221's approach). Plain `.null` glyphs were tried first: at the start of a
/// line they are attached to the previous line fragment, which puts the caret and block chrome
/// on the wrong line.
final class MarkerHidingLayoutDelegate: NSObject, NSLayoutManagerDelegate {
    /// The current selection; `.span` markers touching it are shown.
    var selection = NSRange(location: 0, length: 0)
    /// Ranges of the blocks the selection touches; `.line` markers in them are shown.
    var revealedBlocks: [NSRange] = []

    func isHidden(_ reveal: MarkerReveal) -> Bool {
        !reveal.isRevealed(selection: selection, blockRanges: revealedBlocks)
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
                  isHidden(reveal) else { continue }
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
              isHidden(reveal) else { return action }
        return .zeroAdvancement
    }

    /// Whether the glyph for `charIndex` is currently hidden (tests and probes).
    static func isHiddenGlyph(_ layoutManager: NSLayoutManager, character charIndex: Int) -> Bool {
        let g = layoutManager.glyphIndexForCharacter(at: charIndex)
        let p = layoutManager.propertyForGlyph(at: g)
        return p == .null || p == .controlCharacter
    }
}
