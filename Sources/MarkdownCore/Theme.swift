import AppKit

/// Fonts, colors and paragraph metrics for the rendered markdown.
public struct Theme: @unchecked Sendable {
    public var bodySize: CGFloat = 15
    public var headingSizes: [CGFloat] = [28, 24, 20, 17, 15, 15]
    public var codeSize: CGFloat = 13.5
    public var lineHeightMultiple: CGFloat = 1.35
    public var listIndentPerLevel: CGFloat = 20
    public var quoteIndent: CGFloat = 16

    public var textColor: NSColor = .textColor
    public var markerColor: NSColor = .tertiaryLabelColor
    public var listMarkerColor: NSColor = .secondaryLabelColor
    public var quoteColor: NSColor = .secondaryLabelColor
    public var linkColor: NSColor = .linkColor
    public var codeBackground: NSColor = .quaternarySystemFill

    public init() {}

    public var bodyFont: NSFont { .systemFont(ofSize: bodySize) }
    public var codeFont: NSFont { .monospacedSystemFont(ofSize: codeSize, weight: .regular) }

    public func headingFont(level: Int) -> NSFont {
        .systemFont(ofSize: headingSizes[max(0, min(5, level - 1))], weight: .semibold)
    }

    public func paragraphStyle(headIndent: CGFloat = 0, firstLineHeadIndent: CGFloat = 0,
                               spacingBefore: CGFloat = 0, lineHeightMultiple: CGFloat? = nil) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = lineHeightMultiple ?? self.lineHeightMultiple
        p.headIndent = headIndent
        p.firstLineHeadIndent = firstLineHeadIndent
        p.paragraphSpacingBefore = spacingBefore
        return p
    }

    public var bodyAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: textColor, .paragraphStyle: paragraphStyle()]
    }
}
