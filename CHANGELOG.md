# Changelog

One section per released version, newest first. Each section is drafted from that release's
merged commits and may be AI-written; it is not a "human-written" text. The release workflow
uses the section verbatim as the GitHub Release notes, and the release-note posters
(`ops/announce/`) post from it, so the first line of a section is the one-sentence summary.

Heading format: `## X.Y.Z — YYYY-MM-DD` (the version must match `scripts/check-version.sh`).
`## Unreleased` collects changes until the next release, when it is renamed to `## X.Y.Z — YYYY-MM-DD`.

## Unreleased

Images in an opened folder are listed in the sidebar and open in a read-only viewer.

- PNG, JPEG, GIF, HEIC/HEIF, WebP, TIFF, BMP and AVIF files appear beside the notes with a photo icon.
- Selecting one shows it fitted to the window (never enlarged), with pinch to zoom; GIFs animate and
  the arrow keys step through the folder. The subtitle shows its size in pixels.
- Dropping an image, or Finder › Open With › Markdown Editor, opens its folder with it selected;
  Preview stays the default app for images.

## 0.4.0 — 2026-10-11

The app can now tell you when a new version is out, only if you ask it to.

- Markdown Editor › Check for Updates… asks the download site for the latest version number.
- On the second launch the app asks once whether to check automatically, at most once a day; it
  stays off unless you say yes, and Check for Updates Automatically in the same menu turns it on or off.
- A check is one plain request to markdown.chri5tian.com/version.json; like any web request the site
  sees your IP address, and nothing else is sent.

## 0.3.2 — 2026-10-10

New app icon and a download page restyled to match the app.

- New app icon, full-bleed so macOS 26 masks it, plus site favicons.
- The empty-state message ("Drop a folder here") is easier to read.
- The download page uses the app's own colours and type, with light and dark screenshots.

## 0.3.1 — 2026-10-10

Much faster typing in large tables, a safer installer and marker fixes.

- Tables: typing in a 1,000-row table drops from about 258 ms to 20–28 ms per keystroke. A column
  that widened and then shrank back while editing now realigns.
- Tables: `\|` inside a code span in a cell shows as `|`, as on GitHub; the first column aligns in
  tables that mix rows with and without a leading pipe.
- Editor: inline markers (`**`, backticks) no longer reveal or hide at stale positions after an edit.
- File › New: "Discard Changes" restores the saved text, so a failed create can't re-save discarded text.
- install.sh: replaces an existing copy by staging and swapping, and restores the previous copy if
  the swap fails or is interrupted; Rosetta-aware architecture check.

## 0.3.0 — 2026-10-08

GitHub-style pipe tables render as aligned grids.

- Header row, delimiter row and body rows show as aligned columns with hidden pipes, a header rule
  and faint row separators; `:---:` sets column alignment.
- Put the cursor anywhere in a table to edit its markdown; move it out and the grid comes back. The
  file on disk is never rewritten by the rendering.

## 0.2.0 — 2026-10-08

File › New (⌘N) creates a new note.

- With a folder open, the note goes into the folder selected in the sidebar as `Untitled.md`,
  `Untitled 2.md`, …; with no folder open, a Save panel picks the location.
- A new note can never overwrite an existing file.
- Terminal install: `curl -fsSL https://markdown.chri5tian.com/install.sh | bash` checks the
  SHA-256 and installs without the Open Anyway step.

## 0.1.0 — 2026-10-07

First public release: a free, native macOS markdown editor with inline rendering.

- Markdown renders in place as you type: headings, emphasis, inline code, links, lists, task lists,
  quotes, fenced code, rules and images, in one pane.
- Drop a folder on the window or the Dock icon to open it as a sidebar file tree.
- Saves automatically; a failed save keeps your text and asks before anything is discarded.
- Download from https://markdown.chri5tian.com (signed ad-hoc, not notarized).
