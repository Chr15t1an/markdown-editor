---
# DESIGN.md — Markdown Editor
# Format: Google Labs DESIGN.md (https://github.com/google-labs-code/design.md), alpha.
# Front matter = machine-readable tokens. Prose below = the rationale and the rules.
# Keep this block identical to the code token source: Sources/MarkdownCore/Theme.swift.
# Native app: every colour is a platform semantic NSColor (written as a string alias); there is
# no primitive tier because AppKit owns the raw values and resolves them per appearance.
version: 1
name: Markdown Editor
description: Native macOS markdown editor that renders formatting in place as you type; the UI must make reading and writing one plain .md file at a time effortless.

colors:
  # Semantic tier only. Light/dark resolve inside AppKit. "Theme.x" = the property in Theme.swift
  # that carries it; roles without a Theme property are system defaults the views inherit.
  background:          "NSColor.textBackgroundColor"        # editor scroll view (EditorViewController)
  surface:             "NSSplitViewItem sidebar material"   # sidebar: vibrant source-list material over windowBackgroundColor
  text:                "NSColor.textColor"                  # Theme.textColor — document text
  text-ui:             "NSColor.labelColor"                 # sidebar rows, window title (NSTextField default)
  text-secondary:      "NSColor.secondaryLabelColor"        # Theme.listMarkerColor, Theme.quoteColor
  text-tertiary:       "NSColor.tertiaryLabelColor"         # Theme.markerColor — revealed markdown syntax; empty-state label
  link:                "NSColor.linkColor"                  # Theme.linkColor
  code-background:     "NSColor.quaternarySystemFill"       # Theme.codeBackground — inline code and code blocks
  divider:             "NSColor.separatorColor"             # quote bar, horizontal rule, table rules (alpha ×2 header, ×0.8 rows)
  primary:             "NSColor.controlAccentColor"         # the user's accent; drop-target highlight only
  selection:           "NSColor.selectedContentBackgroundColor"  # sidebar selected row (system)
  on-selection:        "NSColor.alternateSelectedControlTextColor"
  text-selection:      "NSColor.selectedTextBackgroundColor"     # editor selection (system)
  focus-ring:          "NSColor.keyboardFocusIndicatorColor"     # system focus ring, never custom
  # Not defined on purpose: destructive, warning, success, info. The app has no custom status UI;
  # save failures and open errors go through NSAlert (system styling). Add a role when a second use appears.

typography:
  # Document roles mirror Theme.swift. Family is the system font (SF Pro / SF Mono): Theme uses
  # NSFont.systemFont / monospacedSystemFont, never a named face.
  document-body:    { fontFamily: "system", fontSize: 15,   fontWeight: 400, lineHeight: 1.35 }   # Theme.bodySize, lineHeightMultiple
  document-h1:      { fontFamily: "system", fontSize: 28,   fontWeight: 600, lineHeight: 1.15, spaceBefore: 10 }   # Theme.headingSizes[0]
  document-h2:      { fontFamily: "system", fontSize: 24,   fontWeight: 600, lineHeight: 1.15, spaceBefore: 10 }
  document-h3:      { fontFamily: "system", fontSize: 20,   fontWeight: 600, lineHeight: 1.15, spaceBefore: 6 }
  document-h4:      { fontFamily: "system", fontSize: 17,   fontWeight: 600, lineHeight: 1.15, spaceBefore: 6 }
  document-h5:      { fontFamily: "system", fontSize: 15,   fontWeight: 600, lineHeight: 1.15, spaceBefore: 6 }
  document-h6:      { fontFamily: "system", fontSize: 15,   fontWeight: 600, lineHeight: 1.15, spaceBefore: 6 }
  document-code:    { fontFamily: "system-monospaced", fontSize: 13.5, fontWeight: 400, lineHeight: 1.2 }   # Theme.codeSize; inline code scales 13.5/15 of its run
  # UI chrome stays at platform text styles.
  ui-body:          { fontFamily: "system", fontSize: 13,   fontWeight: 400, textStyle: "body" }      # sidebar rows (NSTextField label default)
  ui-empty-state:   { fontFamily: "system", fontSize: 17,   fontWeight: 400, textStyle: "title2" }    # "Drop a folder here" (EditorViewController)

spacing:
  base: 4
  xs: 4
  sm: 8
  md: 16
  lg: 24
  xl: 32
  # Named layout values in code today (see Overview › Follow-ups for the ones not yet in Theme.swift).
  editor-inset-horizontal-min: 28     # EditorViewController.minimumInset
  editor-inset-vertical: 24           # EditorViewController textContainerInset.height
  content-max-width: 760              # EditorViewController.readableWidth — the reading column
  list-indent: 20                     # Theme.listIndentPerLevel
  quote-indent: 16                    # Theme.quoteIndent
  code-block-indent: 12               # MarkdownStyler.base(.fencedCode)
  table-gutter: 12                    # MarkdownStyler.tableGutter — each side of a column boundary
  table-delimiter-strip: 9            # MarkerHidingLayoutDelegate.hiddenDelimiterHeight
  image-gap: 8                        # ImageCache.gap
  image-max-height: 480               # ImageCache.maxHeight
  sidebar-icon: 16                    # SidebarViewController cell
  sidebar-icon-gap: 6
  sidebar-min-width: 180              # MainWindowController split items
  sidebar-max-width: 420
  editor-min-width: 320
  window-default: { width: 1100, height: 750 }

rounded:
  sm: 5        # code-block background (EditorLayoutManager)
  md: 8        # drop-target highlight (DropView)
  # No lg / full: no cards, sheets, pills or avatars exist. Add when one does.

# Not part of the Google schema but read by agents all the same.
elevation:
  0: { surface: "{background}", shadow: "none" }                       # the editor
  1: { surface: "{surface}", shadow: "none", material: "sidebar" }     # the sidebar (vibrancy, not a shadow)
  2: { material: "system" }                                            # menus, find bar — AppKit's own
  3: { material: "system" }                                            # NSAlert sheets and NSOpenPanel/NSSavePanel — AppKit's own
strokes:
  quote-bar: { width: 3, inset: 2, color: "{divider}" }
  horizontal-rule: { width: 1, color: "{divider}" }
  table-header-rule: { width: 1, color: "{divider} alpha ×2" }
  table-row-rule: { width: 1, color: "{divider} alpha ×0.8" }
  drop-highlight: { width: 3, inset: 3, color: "{primary}", rounded: "{rounded.md}" }
motion:
  # No app-authored animation. Sidebar collapse, find bar, sheets and selection use AppKit's
  # defaults, which already honour Reduce Motion. Add durations here only when custom motion appears.
  custom: none

components:
  editor:        { backgroundColor: "{background}", textColor: "{text}", font: "{typography.document-body}", maxWidth: "{spacing.content-max-width}" }
  sidebar-row:   { textColor: "{text-ui}", font: "{typography.ui-body}", selectedBackground: "{selection}", selectedText: "{on-selection}", icon: "SF Symbol folder / doc.text @ 16" }
  code-block:    { backgroundColor: "{code-background}", font: "{typography.document-code}", rounded: "{rounded.sm}", indent: "{spacing.code-block-indent}" }
  inline-code:   { backgroundColor: "{code-background}", font: "{typography.document-code}" }
  block-quote:   { textColor: "{text-secondary}", bar: "{strokes.quote-bar}", indent: "{spacing.quote-indent}" }
  link:          { textColor: "{link}" }
  marker:        { textColor: "{text-tertiary}" }
  list-marker:   { textColor: "{text-secondary}" }
  table:         { headerWeight: 700, headerRule: "{strokes.table-header-rule}", rowRule: "{strokes.table-row-rule}", gutter: "{spacing.table-gutter}" }
  drop-target:   { stroke: "{strokes.drop-highlight}" }
  empty-state:   { textColor: "{text-tertiary}", font: "{typography.ui-empty-state}" }
---

## Overview

Markdown Editor is a small, free, native macOS app (AppKit, Swift package, macOS 15+, Apple
Silicon) for people who want Typora's shape without the price or a vault: one pane, markdown
rendered in place as you type, and any folder you drop on it opened as a sidebar file tree. The
one thing the UI must make easy is reading and writing a single plain `.md` file without ever
switching modes. The mood is calm and sparse: a reading surface with a file list beside it, no
toolbar, no status bar, nothing that competes with the text.

The platform provides almost everything: SF Pro and SF Mono, the semantic colour set and its
light/dark resolution, Increase Contrast, the user's accent colour, the vibrant sidebar material,
selection and focus rings, the find bar, sheets and panels. Brand is deliberately absent from the
chrome — the accent is the user's and the greys are Apple's. Brand lives in the app icon and favicon
(see Shapes › Brand), not in the window. Where the
app does make choices they are in the document: a 15pt reading size, a 760pt column, semibold
headings on a tight scale, and quiet markdown syntax that appears only where the caret is.

**Source of truth in code:** `Sources/MarkdownCore/Theme.swift`. The front matter above mirrors it
exactly; change both in the same commit. Layout constants that still live outside `Theme.swift`
are listed under Follow-ups below with the line they sit on.

**What we kept from the existing code:**

- `Theme.swift` as the token source: body 15, headings 28/24/20/17/15/15 semibold, code 13.5
  monospaced, line height ×1.35, list indent 20, quote indent 16, and six semantic `NSColor`s
  (`textColor`, `tertiaryLabelColor`, `secondaryLabelColor` ×2, `linkColor`,
  `quaternarySystemFill`). No literal hex anywhere in `Sources/`.
- The 760pt readable column centred in wide windows, with a 28pt minimum side inset and 24pt top.
- The source-list sidebar (`NSOutlineView` `.sourceList` style, SF Symbols `folder` /
  `doc.text`, 180–420pt wide, collapsible with ⌘⇧L).
- Full-size-content window, title = folder name with its proxy icon, subtitle = file name (and
  "Not saved: …" when a save fails). No toolbar.
- Block chrome drawn by `EditorLayoutManager`: code-block fill at radius 5, a 3pt quote bar, a
  1pt horizontal rule, table rules derived from `separatorColor`.
- The drop-target highlight: a 3pt `controlAccentColor` rounded stroke inset 3pt.
- The public download site (`site/style.css`) has its own web palette (`#0a66d8` accent, `#1d1d1f`
  text). It is a marketing page, not the app, and is out of scope here; it should not leak into
  the app and the app's greys should not be forced onto it.

**Decisions made in this pass (no one to ask, so stated here):**

- No primitive tier. On a native app the raw values belong to AppKit; the Colors table records
  what they resolve to on macOS 26 so contrast can be checked, but code never reads a hex.
- Document type sizes are a stated exception to the 13pt UI body: this is a reading surface, so
  15pt body / 28pt H1 are deliberate, and chrome stays at system sizes.
- Unused semantic roles (destructive, warning, success, info, surface-raised, disabled) are left
  undefined rather than invented. Errors are `NSAlert`s; there are no custom status colours.
- Radius 5 for the code block is kept as-is rather than rounded to the 4/8 scale: it is the value
  on screen today and changing it is not this task.
- Motion stays "none custom"; the token block says so instead of inventing durations.

**Follow-ups** — raw literals outside `Theme.swift` that belong in it (file:line, value, suggested
token). Not refactored in this pass:

- `Sources/MarkdownEditor/EditorViewController.swift:6` — `readableWidth = 760` → `Theme.readableWidth`
- `Sources/MarkdownEditor/EditorViewController.swift:7` — `minimumInset = 28` → `Theme.editorInsetHorizontalMin`
- `Sources/MarkdownEditor/EditorViewController.swift:53,103` — vertical inset `24` (twice) → `Theme.editorInsetVertical`
- `Sources/MarkdownEditor/EditorViewController.swift:69` — `emptyLabel.textColor = .tertiaryLabelColor` → `Theme.emptyStateColor`; and raise it to `secondaryLabelColor` (see Colors: 1.88:1 light / 2.27:1 dark fails even the large-text floor)
- `Sources/MarkdownEditor/EditorViewController.swift:70` — `.systemFont(ofSize: 17)` → `NSFont.preferredFont(forTextStyle: .title2)` via `Theme.emptyStateFont`
- `Sources/MarkdownEditor/EditorLayoutManager.swift:20` — `NSColor.quaternarySystemFill` → `theme.codeBackground` (same value, second copy)
- `Sources/MarkdownEditor/EditorLayoutManager.swift:21` — radius `5`, vertical outset `2` → `Theme.codeBlockRadius`, `Theme.codeBlockPadding`
- `Sources/MarkdownEditor/EditorLayoutManager.swift:26-27` — `NSColor.separatorColor`, bar width `3`, inset `2` → `Theme.dividerColor`, `Theme.quoteBarWidth`, `Theme.quoteBarInset`
- `Sources/MarkdownEditor/EditorLayoutManager.swift:32` — `NSColor.separatorColor` (horizontal rule) → `Theme.dividerColor`
- `Sources/MarkdownEditor/EditorLayoutManager.swift:51` — image offset `4` below the line → `Theme.imageGap / 2` or its own name
- `Sources/MarkdownEditor/EditorLayoutManager.swift:93-97` — `tableRuleColors()` derives from `separatorColor` with alpha ×2 / ×0.8 → `Theme.tableHeaderRuleColor`, `Theme.tableRowRuleColor`
- `Sources/MarkdownEditor/EditorLayoutManager.swift:104` — fallback `.systemFont(ofSize: 15)` → `theme.bodyFont`
- `Sources/MarkdownCore/MarkdownStyler.swift:131` — `tableGutter = 12` → `Theme.tableGutter`
- `Sources/MarkdownCore/MarkdownStyler.swift:191` — heading `spacingBefore` `10` (H1–H2) / `6` (H3–H6) → `Theme.headingSpacingBefore`
- `Sources/MarkdownCore/MarkdownStyler.swift:192` — heading `lineHeightMultiple: 1.15` → `Theme.headingLineHeightMultiple`
- `Sources/MarkdownCore/MarkdownStyler.swift:198` — code-block indent `12`, `lineHeightMultiple: 1.2` → `Theme.codeBlockIndent`, `Theme.codeLineHeightMultiple`
- `Sources/MarkdownEditor/DropView.swift:53-55` — `NSColor.controlAccentColor`, inset `3`, radius `8`, line width `3` → `Theme.accentColor`, `Theme.dropHighlight{Inset,Radius,Stroke}`
- `Sources/MarkdownEditor/SidebarViewController.swift:176-181` — icon width `16`, icon↔label gap `6`, cell inset `2` → `Theme.sidebarIconSize`, `Theme.sidebarIconGap`, `Theme.sidebarCellInset`
- `Sources/MarkdownEditor/MainWindowController.swift:18,37,47` — window `1100×750` (three copies) → `Theme.defaultWindowSize`
- `Sources/MarkdownEditor/MainWindowController.swift:28-32` — sidebar `180`/`420`, editor min `320` → `Theme.sidebarMinWidth`, `Theme.sidebarMaxWidth`, `Theme.editorMinWidth`
- `Sources/MarkdownEditor/ImageCache.swift:7-8` — `maxHeight = 480`, `gap = 8` → `Theme.imageMaxHeight`, `Theme.imageGap`
- `Sources/MarkdownEditor/MarkerHidingLayoutDelegate.swift:72` — `hiddenDelimiterHeight = 9` → `Theme.tableDelimiterStripHeight`

## Colors

There is no palette to choose: every colour is a semantic `NSColor`, so light mode, dark mode and
Increase Contrast are the system's, and the dark theme is Apple's designed dark (raised surfaces,
reduced-alpha greys), not an inversion. The editor sits on `textBackgroundColor` and the sidebar
on the vibrant sidebar material, which is what makes the file list read as a lighter, secondary
surface in both appearances without a single custom value.

Roles, and what each is reserved for:

- **text** (`textColor`) — document text, headings, code. Never dimmed for emphasis; weight and
  size do that.
- **text-secondary** (`secondaryLabelColor`) — things that are part of the content but not the
  point of it: block-quote text, list bullets and numbers, image alt text.
- **text-tertiary** (`tertiaryLabelColor`) — markdown syntax when it is revealed (`#`, `**`,
  `` ` ``, link URLs, table pipes). It is meant to be nearly invisible: the caret reveals it, and
  the reader is not expected to read it. Also, today, the empty-state label — which it is too faint
  for; see Follow-ups.
- **link** (`linkColor`) — link text only. ⌘-click opens it; the colour is the only affordance,
  which is acceptable because the document is otherwise monochrome and the cursor changes.
- **code-background** (`quaternarySystemFill`) — inline code and fenced blocks. A 2.7 %-alpha fill:
  present, never loud.
- **divider** (`separatorColor`) — quote bar, horizontal rule, table rules. Decorative, never the
  only cue (the quote is also indented and dimmed; the rule is also a blank line in the source).
- **primary** (`controlAccentColor`) — the user's accent. Used for exactly one thing: the
  drop-target outline while a folder is dragged over the window. It is not used decoratively and
  not for links (links use `linkColor`, which the system keeps distinct).
- **selection / focus-ring / text-selection** — the system's; never overridden.

Contrast, checked with `contrast.py` against the values the semantic colours resolve to on macOS 26
(sRGB, alpha colours composited over their background first; light bg `#FFFFFF`, dark bg
`#1E1E1E`):

| Pair | Light | Dark | Target | Result |
|---|---|---|---|---|
| text / background (`#000000`, `#FFFFFF`) | 21.00:1 | 16.67:1 | ≥ 4.5 | pass |
| text-ui / sidebar (`#272727`, `#DDDDDD`) | 14.94:1 | 12.27:1 | ≥ 4.5 | pass |
| text / code-background (`#F8F8F8`, `#242424`) | 19.77:1 | 15.52:1 | ≥ 4.5 | pass |
| link / background (`#0068DA`, `#419CFF`) | 5.26:1 | 5.89:1 | ≥ 4.5 | pass |
| text-secondary / background (`#808080`, `#9A9A9A`) | **3.95:1** | 5.92:1 | ≥ 4.5 | light fails AA for 15pt regular (quote text, list markers) |
| text-tertiary / background (`#BDBDBD`, `#565656`) | **1.88:1** | **2.27:1** | ≥ 4.5 (≥ 3 if decorative) | fails — acceptable for revealed syntax, not for the empty-state label |
| on-selection / selection (`#FFFFFF` on `#0064E1`, `#0059D1`) | 5.37:1 | 6.27:1 | ≥ 4.5 | pass |
| text / text-selection (`#B3D7FF`, `#3F638B`) | 14.08:1 | 6.23:1 | ≥ 4.5 | pass |
| primary / background (`#007AFF`, non-text stroke) | 4.02:1 | 4.15:1 | ≥ 3 | pass |
| focus-ring / background (`#80B3FA`, `#1C638E`, 50 % alpha) | 2.15:1 | 2.56:1 | ≥ 3 | system ring; drawn over the control edge, not flat on the background — platform-owned |
| divider / background (`#E6E6E6`, `#343434`) | 1.25:1 | 1.34:1 | decorative | never the sole cue |
| table-header-rule / background (`#CDCDCD`, `#4A4A4A`) | 1.59:1 | 1.88:1 | decorative | header is also bold |
| table-row-rule / background (`#EBEBEB`, `#303030`) | 1.19:1 | 1.26:1 | decorative | rows also align on the grid |

Two results need a decision, both platform-level: Apple's `secondaryLabelColor` on white is
3.95:1, under the 4.5 AA floor for 15pt regular text, and `tertiaryLabelColor` is under 3:1 in
both appearances. Increase Contrast fixes both at the system level (the semantic colours darken),
which is the HIG's answer. Within the app: keep revealed syntax on tertiary (it is a hint, not
content, and the raw characters are also selectable and copyable), move the empty-state label to
`secondaryLabelColor`, and treat quote text / list markers on light as accepted-with-eyes-open
until a reader complains — do not replace the system colour with a darker literal.

## Typography

One family: the system font, SF Pro for text and SF Mono for code, via `NSFont.systemFont` and
`monospacedSystemFont`. No named face, so the app follows the system's font smoothing, Dynamic
Type on Apple silicon and future system font changes for free.

The document scale is the one deliberate departure from platform sizes. Body is 15pt regular at
×1.35 line height — larger than the 13pt UI body because this is a reading surface, and the
user's window is usually wide. Headings are semibold (weight carries hierarchy; size is tight):
28 / 24 / 20 / 17 / 15 / 15 at ×1.15, with 10pt of space before H1–H2 and 6pt before H3–H6. H5
and H6 share the body size on purpose — they differ from body only by weight, and from each other
not at all; deeper nesting is rare in notes and a seventh size would not help. Code is 13.5pt
mono at ×1.2 for blocks; inline code scales to 13.5⁄15 of whatever run it sits in, so it stays
proportional inside a heading. Bold, italic and strikethrough are symbolic traits on the current
font, never a different face. Table header cells are bold.

Line length is governed by the 760pt readable column (see Layout): at 15pt SF that is roughly
85–95 characters at the widest, which is above the ~75 comfortable ceiling and is the known
cost of a one-column editor that also has to show wide tables; a table wider than the column
falls back to source rather than scrolling.

UI chrome stays at system text styles: sidebar rows at the label default (Body, 13pt), the window
title and subtitle at the system's. The empty-state label is 17pt regular, which is Title 2;
it should be expressed as that text style (Follow-ups). Minimum size anywhere is 13pt UI, 13.5pt
document.

## Layout

Two panes in an `NSSplitViewController`: the sidebar (180–420pt, collapsible, ⌘⇧L) and the editor
(min 320pt). The window opens at 1100×750, full-size content view, and restores its frame and
split position. There is no toolbar and no status bar; the title bar carries the folder name with
its proxy icon and the file name as subtitle.

The editor is a single column of text, `content-max-width` 760pt, centred when the pane is wider
than that, with a minimum 28pt inset on each side and 24pt at the top. The column width drives
everything that has to fit: images scale to it (max height 480, 8pt gap below), and a table whose
rows cannot fit it shows as source instead of overflowing.

Spacing inside the document is set by the markdown, not by a grid: paragraphs are separated by
their own blank lines (the source is the layout), headings add 10 / 6pt before, lists indent 20pt
per level with the bullet hanging in the indent, quotes indent 16pt behind a 3pt bar, code blocks
indent 12pt inside their fill, table columns have 12pt of gutter each side of a boundary and a 9pt
strip where the hidden delimiter row was. Left-aligned throughout; the only centred text is the
empty-state label.

Sidebar rows are the source-list default row with a 16pt SF Symbol, 6pt to the label, 2pt cell
inset, middle-truncated names. Folders expand in place; expansion state is remembered per folder.

Base unit 4pt; the named values above are the ones that exist. Do not add a spacing token for a
value used once.

## Elevation & Depth

Level 0 is the editor: flat `textBackgroundColor`, no shadow, no border. Level 1 is the sidebar,
and its depth comes from the system's vibrant sidebar material rather than a shadow or a tint —
in dark mode that is what makes it read as a slightly lifted surface. Level 2 (menus, the find
bar) and level 3 (alert sheets, open/save panels) are AppKit's own; the app draws none of them.

Inside the document, "depth" is a fill or a stroke, never a shadow: the code block's 2.7 %-alpha
fill at radius 5, the quote bar, the hairline rules. Dark mode gets the same recipe with the
system's dark values — no heavier shadows, no custom tints. If a custom popover or sheet is ever
added, use an `NSVisualEffectView` material, not a drawn shadow.

## Shapes

Two radii in use: 5pt on the code-block fill (a soft edge on a block of text) and 8pt on the
drop-target outline (a window-sized frame, so a larger radius). There are no cards, pills,
avatars or sheets of the app's own, so no `lg` or `full` level is defined; add one when a second
use appears, and keep one radius per hierarchy level rather than one per view.

Icons are SF Symbols at the sidebar's 16pt: `folder` and `doc.text`, regular weight, matching the
row's text style. No other icons exist. Illustration: none; the empty state is a sentence.

### Brand

**Concept.** The app's one signature behaviour is that markdown renders in place while you type:
a faint `#` stays visible beside the bold heading it produced, with the caret between them. The
mark is exactly that, taken from the app's own screenshot. A paper-white plate (like TextEdit and
Notes, which it sits beside), a grey `#` in the marker colour, a system-blue caret, a heavy ink
heading bar, and three body lines.

**Rejected.** The `M↓` Markdown mark, which is the category default and says "markdown" rather
than "this editor". A folder with a page, which reads as Finder or Files. A `#` morphing into a
bar, which turned to mush at 16px.

**Tests.**

| Test | Result |
|---|---|
| Silhouette | A plate with a bar and lines; distinct from TextEdit's ruled page and Notes' yellow header. |
| 16px | The small variant drops the caret and keeps `#`, bar and one line; reads as a page with a heading. |
| One colour | `mark.svg` works flat; the caret can go to the same ink. |
| Light / dark | Checked on both Dock backgrounds; the paper plate carries itself, like TextEdit. |

**Colours** come from the UI, not a new brand palette. Ink `#1D1D1F`, marker grey `#A1A1A8`, body
lines `#C9C9CF`, caret `#007AFF` (system blue, the default accent).

**Files.** Sources are in `brand/`, with rebuild steps in `brand/README.md`. The build writes
`Resources/AppIcon.icns`, which `Info.plist` names with `CFBundleIconFile`. It also writes the
site's `favicon.svg`, `favicon-32.png` and `apple-touch-icon.png`.

**Shape.** The `.icns` is a full-bleed opaque square, and macOS 26 applies the rounded mask. A
classic-shape `.icns` was tried first and macOS 26.6 put it on a grey plate. On macOS 15 the
full-bleed icon shows as a square; that is the accepted cost until there is an Icon Composer
build.

**Follow-up.** An Icon Composer `.icon` compiled to `Assets.car`, plus a classic `.icns` for
macOS 15, fixes both systems and adds the Clear and Tinted appearances. It needs Xcode 26.

## Components

The real inventory. State is never conveyed by colour alone: selection has a row fill *and* the
system's inverted text, focus is the system ring, drop is a stroke that appears and disappears,
errors are sheets with words.

**Editor (`MarkdownTextView` in `EditorViewController`)** — the document. Default: body text on
`background`, caret in `text`. Focus: first responder on open; the text caret is the focus
indicator (no ring on a text view, per platform). Selected text: `text-selection` fill. Typing in
a block: that block's markers reveal in `text-tertiary`; leaving it hides them again (reveal is
per block for line markers, per span for inline). IME composition: styling pauses until commit.
Loading: none — files open synchronously; large files restyle incrementally. Error: a save
failure keeps the text, sets the subtitle to "Not saved: …", and shows a warning sheet once.
Empty: see Empty state.

**Headings** — semibold at the level's size; `#` markers hidden until the caret enters the line.

**Paragraph / emphasis** — bold, italic, strikethrough, inline code (`code-background` fill,
mono at proportional size), links (`link` colour, ⌘-click opens, pointer is the system's).
Markers hide per span and reveal when the selection touches them.

**Lists** — bullet, ordered and task items. Markers stay visible and dimmed (`text-secondary`)
rather than hidden, because hiding them made editing fragile; the bullet hangs in a 20pt indent.
Return continues the list, Return on an empty item ends it, Tab / ⇧Tab change the level.

**Block quote** — `text-secondary` text indented 16pt behind a 3pt `divider` bar; the `>` is a
hidden line marker.

**Code block** — `code-background` fill at radius 5, 12pt inner indent, mono 13.5 at ×1.2; the
fence lines are hidden line markers. Revealed when the caret is inside.

**Horizontal rule** — a 1pt `divider` line replacing the `---` line while the caret is elsewhere.

**Table** — GitHub pipe tables laid out as a grid: bold header, a header rule (divider at ×2
alpha), hairlines between body rows (×0.8 alpha), 12pt gutters, column alignment from the
delimiter row. Caret inside: the source is shown with dimmed pipes; caret leaves: the grid comes
back. Too wide for the column: stays as source with pipes in `text-tertiary` — that is the
"doesn't fit" state, and it is also a visible layout change, not just a colour.

**Image** — an image-only paragraph draws the file below its line, scaled to the column (max
480pt high), source hidden; a missing or remote image shows the source text in
`text-secondary` and reserves nothing. Images never load over the network.

**Sidebar (`SidebarViewController`)** — source-list outline of the open folder. Default row:
icon + name in `text-ui`. Hover: none (source lists do not hover). Selected: system
`selection` fill with `on-selection` text, a persistent state that also moves the editor to that
file. Focus: the outline's system focus ring and keyboard navigation (arrows, type-to-select).
Expanded/collapsed: the disclosure triangle. External change: rows reload in place and the
selection is kept. Empty folder: the outline is simply empty; the editor's empty state carries
the message.

**Drop target (`DropView`)** — the whole window. Drag of an openable folder or `.md` file over
it: a 3pt `primary` stroke, radius 8, inset 3, over everything. Exit or drop: it disappears.
Non-openable drag: nothing (the operation is refused, no stroke).

**Window** — title = folder name (proxy icon drag-able), subtitle = file name, or
"File.md — Not saved: reason" while a save is failing. No toolbar. Close with unsaved
*unsaveable* edits: the Keep Editing / Discard Changes sheet; saves that succeed never prompt.

**Empty state** — centred `ui-empty-state` text in the editor pane: "Drop a folder here" at
launch with nothing restored, "Select a file" when a folder is open and no file is, "“Name” was
deleted or moved to the Trash" when the open file disappears. One sentence, no button; the action
is the drag or the sidebar.

**Alerts** — `NSAlert` sheets only: open failure ("Couldn’t open “X”"), create failure
("Couldn’t create a new note in “X”"), save failure ("Your changes couldn’t be saved", with the
reason and what happens next), and the critical Keep Editing / Discard Changes choice. Titles
say what happened; body says why and what to do.

**Menus** — the standard App / File / Edit / Format / View / Window menus built in code; Format
holds the markdown actions with their ⌘ shortcuts. No custom menu styling.

## Do's and Don'ts

- Do read `Theme` (and the semantic `NSColor`s) only; never a hex, an `NSColor(white:)`, or a
  bare point size in a view. The Follow-ups list is the debt; do not add to it.
- Do keep document type on `Theme` sizes and chrome on system text styles; the 15pt body is a
  reading-surface exception, not a licence to size UI by hand.
- Do keep the platform's focus ring, selection colours, sidebar material and accent. If a custom
  control ever needs a focus indicator, draw one ≥ 2pt in `controlAccentColor`.
- Do let Increase Contrast and Reduce Motion work by using system colours and system animation;
  gate any future custom animation on `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`.
- Do express every state with something other than colour: a stroke that appears, a weight, a
  sheet with words, a layout change.
- Do write alert titles as what happened ("Your changes couldn’t be saved") and buttons as verbs
  ("Keep Editing", "Discard Changes"), sentence case, no apology.
- Don't use the accent colour for anything but the drop outline. It is not a brand colour; it is
  the user's.
- Don't override Apple's greys with darker literals to "fix" the `secondaryLabelColor` light-mode
  contrast; the fix is Increase Contrast or a different semantic colour.
- Don't add a toolbar, status bar, word count, theme picker or preview toggle. The README's scope
  line ("anything beyond that is out of scope until it's actually missed") is a design rule.
- Don't hide list markers, add icons to headings, colour headings, or draw shadows in the
  document. The document is monochrome text with quiet fills and hairlines.
- Don't add a token for a value used once, and don't define semantic roles the app has no use for.
- Don't let the download site's palette (`site/style.css`) into the app, or the app's into the site.
