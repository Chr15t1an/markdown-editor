import AppKit

/// The app's design tokens: fonts, colours, paragraph metrics and layout values. DESIGN.md's
/// front matter mirrors this file; change both together. Nothing outside this file should hold a
/// raw point size, colour or layout constant.
public struct Theme: @unchecked Sendable {
    // MARK: Document type

    public var bodySize: CGFloat = 15
    public var headingSizes: [CGFloat] = [28, 24, 20, 17, 15, 15]
    /// Space before a heading, by level (H1…H6).
    public var headingSpacingBefore: [CGFloat] = [10, 10, 6, 6, 6, 6]
    public var headingLineHeightMultiple: CGFloat = 1.15
    public var codeSize: CGFloat = 13.5
    public var codeLineHeightMultiple: CGFloat = 1.2
    public var lineHeightMultiple: CGFloat = 1.35

    // MARK: Document layout

    public var listIndentPerLevel: CGFloat = 20
    public var quoteIndent: CGFloat = 16
    /// Inner indent of a fenced code block, inside its fill.
    public var codeBlockIndent: CGFloat = 12
    /// Space on each side of a table column boundary.
    public var tableGutter: CGFloat = 12
    /// Height a table's delimiter row keeps while hidden: a strip for the header rule.
    public var tableDelimiterStripHeight: CGFloat = 9
    /// Extra space reserved below an image-only paragraph (the image is drawn half of it down).
    public var imageGap: CGFloat = 8
    public var imageMaxHeight: CGFloat = 480

    // MARK: Editor pane

    /// The readable text column, centred in wide windows.
    public var readableWidth: CGFloat = 760
    public var editorInsetHorizontalMin: CGFloat = 28
    public var editorInsetVertical: CGFloat = 24

    // MARK: Block chrome

    public var codeBlockRadius: CGFloat = 5
    /// How far the code-block fill extends above and below its text.
    public var codeBlockPadding: CGFloat = 2
    public var quoteBarWidth: CGFloat = 3
    public var quoteBarInset: CGFloat = 2
    /// Thickness of the horizontal rule and the table rules.
    public var ruleWidth: CGFloat = 1
    /// Table rules scale `dividerColor`'s alpha: up for the header rule, down for row rules.
    public var tableHeaderRuleAlphaScale: CGFloat = 2
    public var tableRowRuleAlphaScale: CGFloat = 0.8

    // MARK: Window chrome

    public var defaultWindowSize = NSSize(width: 1100, height: 750)
    public var sidebarMinWidth: CGFloat = 180
    public var sidebarMaxWidth: CGFloat = 420
    public var editorMinWidth: CGFloat = 320
    public var sidebarIconSize: CGFloat = 16
    public var sidebarIconGap: CGFloat = 6
    public var sidebarCellInset: CGFloat = 2
    public var dropHighlightInset: CGFloat = 3
    public var dropHighlightRadius: CGFloat = 8
    public var dropHighlightStroke: CGFloat = 3

    // MARK: Colours

    public var backgroundColor: NSColor = .textBackgroundColor
    public var textColor: NSColor = .textColor
    public var markerColor: NSColor = .tertiaryLabelColor
    public var listMarkerColor: NSColor = .secondaryLabelColor
    public var quoteColor: NSColor = .secondaryLabelColor
    public var linkColor: NSColor = .linkColor
    public var codeBackground: NSColor = .quaternarySystemFill
    public var dividerColor: NSColor = .separatorColor
    public var accentColor: NSColor = .controlAccentColor
    public var emptyStateColor: NSColor = .secondaryLabelColor

    // MARK: UI type

    public var emptyStateFont: NSFont = .preferredFont(forTextStyle: .title2)

    public init() {}

    public var bodyFont: NSFont { .systemFont(ofSize: bodySize) }
    public var codeFont: NSFont { .monospacedSystemFont(ofSize: codeSize, weight: .regular) }

    public func headingFont(level: Int) -> NSFont {
        .systemFont(ofSize: headingSizes[max(0, min(5, level - 1))], weight: .semibold)
    }

    public func headingSpacing(level: Int) -> CGFloat {
        headingSpacingBefore[max(0, min(5, level - 1))]
    }

    /// The table header rule: `dividerColor` with its alpha scaled up, resolved for the current
    /// (drawing) appearance. separatorColor is mostly transparent, so scale rather than replace it.
    public var tableHeaderRuleColor: NSColor {
        let base = resolvedDivider
        return base.withAlphaComponent(min(1, base.alphaComponent * tableHeaderRuleAlphaScale))
    }

    /// The hairline between table body rows: `dividerColor` with its alpha scaled down.
    public var tableRowRuleColor: NSColor {
        let base = resolvedDivider
        return base.withAlphaComponent(base.alphaComponent * tableRowRuleAlphaScale)
    }

    private var resolvedDivider: NSColor {
        dividerColor.usingColorSpace(.sRGB) ?? NSColor(white: 0.5, alpha: 0.1)
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
