# Markdown Editor

A native macOS markdown editor that renders formatting inline as you type, and opens any folder you drop on it as a file tree.

## Why this exists

Typora is the right shape for editing markdown — one pane, WYSIWYG, open any folder with no vault setup — but it's paid ($15 after the trial). Obsidian only works on vaults and VS Code treats markdown as raw text plus a preview pane. This is a small, free, native alternative that does just the parts that matter:

- Typora-style inline editing: markdown syntax renders in place while you type, no preview toggle —
  including GitHub-style pipe tables.
- Drag a folder onto the window or the Dock icon and it opens to that folder, with a sidebar file tree.
- Images in the folder (PNG, JPEG, GIF, HEIC/HEIF, WebP, TIFF, BMP, AVIF) are listed in the sidebar beside the notes and open read-only, fitted to the window, with pinch to zoom. Finder's Open With lists the app for those formats without replacing Preview.

Anything beyond that (themes, export, plugins, editing images) is out of scope until it's actually missed.

## Install

On a Mac with Apple Silicon and macOS 15 or later, paste this into Terminal:

```sh
curl -fsSL https://markdown.chri5tian.com/install.sh | bash
```

It downloads the release zip, checks its SHA-256 against the one written into the script (and stops,
installing nothing, if they differ), installs **Markdown Editor** to `/Applications` (or
`~/Applications` if `/Applications` is not writable), replaces and quits any copy already there, and
opens it. No sudo. Because curl does not mark the download as quarantined, macOS opens it without
the Open Anyway step (it still runs its usual malware scan). To read the script first:
`curl -fsSL https://markdown.chri5tian.com/install.sh | less`.

Or download the zip from **https://markdown.chri5tian.com**, unzip it and move **Markdown Editor**
to Applications. The app is signed ad-hoc, not with an Apple Developer ID, and is not notarized, so
macOS blocks the first launch of a downloaded copy. Double-click it, click **Done**, then open System
Settings › Privacy & Security, scroll to Security. Next to the notice that "Markdown Editor" was
blocked to protect your Mac, click **Open Anyway**. Confirm, authenticate, and it opens normally
from then on. The site lists the steps and the zip's SHA-256.

## Building from source

Requires macOS 15 or later on Apple Silicon. Building from source skips the Gatekeeper prompt,
because nothing is quarantined.

```sh
scripts/make-app.sh             # build + sign "build/Markdown Editor.app"
scripts/make-app.sh --install   # same, then copy it to /Applications (quits a running copy first)
```

The script picks the toolchain itself:

- **Xcode 16** at `/Applications/Xcode.app` (it does not need to be the selected developer
  directory): builds with `swift build`.
- **Command Line Tools only** (no Xcode): builds with two plain `swiftc` calls against the CLT's
  `MacOSX.sdk`.

Run the tests with `scripts/test.sh` (optionally a filter such as `scripts/test.sh BlockScannerTests`).
With Xcode it runs `swift test`; with only the Command Line Tools, where `swift test` and XCTest are
not available, it builds the suite with `swiftc` against a small XCTest stand-in
(`scripts/test-support/`) and runs it headless.

To cut a release (zip, SHA-256 and the download site), see [`docs/release.md`](docs/release.md).
What changed in each version: [`CHANGELOG.md`](CHANGELOG.md).

## Using it

Open a folder any of these ways; it replaces the one that is open:

- drag a folder (or a `.md` file) onto the window or the Dock icon
- File › Open… (⌘O), or File › Open Recent
- `open -a "Markdown Editor" ~/Notes`

File › New (⌘N) creates an empty `Untitled.md` (then `Untitled 2.md`, …) in the folder selected in
the sidebar (or the open file's folder), selects it and puts the cursor in it — rename it in Finder.
With no folder open, it asks where to save the new note and opens that folder.

Opening a single `.md` file selects it in place when it is inside the folder already open;
a file from anywhere else opens its own folder with that file selected. The last folder and file
reopen at launch. Files save automatically a second after you stop typing, when you switch files,
and when the window closes or the app quits; ⌘S saves now. There is no "unsaved changes" prompt
while saves succeed. If a save fails (read-only file, disk full), the text stays in the editor, the
title bar says "Not saved", and switching away or quitting asks Keep Editing / Discard Changes.
⌘⇧L toggles the sidebar.

**Updates.** Markdown Editor › Check for Updates… asks the download site whether a newer version
exists and, if so, offers **Download** (which opens the site). The app makes no network request
otherwise. On the second launch it asks once whether to check automatically; if you turn on
update checks (or tick Markdown Editor › Check for Updates Automatically), the app asks the download
site (markdown.chri5tian.com) once a day for the latest version number — like any web request, the site sees your IP address;
nothing else is sent. No tracking.

Editing: ⌘B bold, ⌘I italic, ⌘⇧` code, ⌘⇧X strikethrough, ⌘K link, ⌘1–⌘6 heading, ⌘0 paragraph.
Return continues a list, task list or quote (Return on an empty item ends it); Tab / ⇧Tab indent
list items. ⌘-click a link to open it.

Tables (GitHub-style `| a | b |` rows over a `|---|---|` line, `:--:` to center a column) show as
aligned columns with a rule under the header; put the cursor anywhere in a table to edit its
markdown, and the columns come back when it leaves. A table too wide for the window stays as text.

### Folder access prompts (one-time certificate)

Notes under `~/Documents` are protected by macOS. The first time the app reads a folder there you
get a "would like to access files in your Documents folder" prompt — allow it. Without a signing
certificate the app is signed ad-hoc, macOS treats every rebuild as a new app, and the prompt comes
back after each `make-app.sh`. To make the grant stick, create a self-signed certificate once:

1. Keychain Access › Certificate Assistant › Create a Certificate…
2. Name: `Markdown Editor Dev`, Identity Type: Self Signed Root, Certificate Type: Code Signing.
3. Re-run `scripts/make-app.sh --install`.

The script uses that identity automatically when it exists. If a grant goes stale anyway:
`tccutil reset SystemPolicyDocumentsFolder com.chri5tian.markdown-editor`, then relaunch and allow.

## Stack

Native macOS (Swift, SwiftUI/AppKit). No Electron, no web view shell.

## License

MIT — see [`LICENSE`](LICENSE).
