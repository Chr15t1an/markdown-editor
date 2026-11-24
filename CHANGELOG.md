# Changelog

One section per released version, newest first. Each section is drafted from that release's
merged commits and may be AI-written; it is not a "human-written" text. The release workflow
uses the section verbatim as the GitHub Release notes, and the release-note posters
(`ops/announce/`) post from it, so the first line of a section is the one-sentence summary.

Heading format: `## X.Y.Z — YYYY-MM-DD` (the version must match `scripts/check-version.sh`).
`## Unreleased` collects changes until the next release, when it is renamed to `## X.Y.Z — YYYY-MM-DD`.

## 0.8.0 — 2026-11-24

Several windows at once, and a default notes folder that new windows and plain launches open.

- File › New Window (⇧⌘N) opens another window; windows cascade from the one in front.
- File › Use as Default Folder makes the window’s folder the default (a checkmark; choose it again
  to clear it). New windows open it, and a plain launch opens it instead of the last folder —
  reopening the last note only when it is inside it. With no default, launch works as before.
- New, Open… and Save act on the window you are in.
- A note is open in one window at a time: opening it in another window brings the window that has
  it forward, and Save As or Move To onto it is refused.
- Quitting, installing an update and switching apps save every window; a note that can't be saved
  still asks Keep Editing / Discard Changes, window by window.

## 0.7.0 — 2026-11-20

Updates install themselves: Check for Updates offers Install and Relaunch instead of a trip to the website.

- When a newer version exists, **Install and Relaunch** saves your note, downloads the release,
  verifies it, swaps it in place of the running app and reopens it. Nothing to paste into Terminal.
- The release is checked before anything is replaced: an Ed25519 signature over its version and
  SHA-256 (the public key ships in the app), the zip's SHA-256, and the new app's code signature,
  bundle id and version. Any failure leaves the current copy as it was and offers **Download**.
- A copy that can't replace itself (still in Downloads under macOS App Translocation, or in a folder
  you can't write to) keeps the old **Download** button.
- This version is the last one to install by hand; from here on, updates arrive in the app.

## 0.6.0 — 2026-11-19

Task lists show checkboxes you can tick, and the File menu gains Save As… and Move To….

- `- [ ]` and `- [x]` items draw a checkbox in place of the markdown; click it to tick or untick,
  and the file saves `[x]` or `[ ]`. ⌘Z undoes it, and Format › Toggle Task (⇧⌘U) does the same
  from the keyboard. Checked items dim their text.
- Put the cursor on a task line to see and edit its `- [ ]` source; nothing moves when it appears.
- File › Save As… (⇧⌘S) saves the note under a new name or folder and keeps editing the copy;
  File › Move To… moves the note or the image on screen into another folder and keeps it open, and never
  replaces a file already there.

## 0.5.0 — 2026-11-11

Images in an opened folder open in a read-only viewer, and tables too wide for the column wrap their cells.

- PNG, JPEG, GIF, HEIC/HEIF, WebP, TIFF, BMP and AVIF files appear beside the notes with a photo icon.
- Selecting one shows it fitted to the window (never enlarged), with pinch to zoom; GIFs animate and
  the arrow keys step through the folder. The subtitle shows its size in pixels.
- Dropping an image, or Finder › Open With › Markdown Editor, opens its folder with it selected;
  Preview stays the default app for images.
- Tables too wide for the column now wrap their cells to fit instead of showing as raw markdown.
  Columns get room by how much text they hold; put the cursor in the table to edit its source.

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
