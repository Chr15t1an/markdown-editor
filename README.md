# Markdown Editor

A native macOS markdown editor that renders formatting inline as you type, and opens any folder you drop on it as a file tree.

## Why this exists

Typora is the right shape for editing markdown — one pane, WYSIWYG, open any folder with no vault setup — but it's paid ($15 after the trial). Obsidian only works on vaults and VS Code treats markdown as raw text plus a preview pane. This is a small, free, native clone that does just the parts that matter:

- Typora-style inline editing: markdown syntax renders in place while you type, no preview toggle.
- Drag a folder onto the window or the Dock icon and it opens to that folder, with a sidebar file tree.

Anything beyond that (themes, export, plugins) is out of scope until it's actually missed.

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
  directory): builds with `swift build`. Run the test suite with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.
- **Command Line Tools only** (no Xcode): builds with two plain `swiftc` calls against the CLT's
  `MacOSX.sdk`. `swift test` does not work on this path — XCTest ships with Xcode — so tests need
  an Xcode install.

To cut a release (zip, SHA-256 and the download site), see [`docs/release.md`](docs/release.md).

## Using it

Open a folder any of these ways; it replaces the one that is open:

- drag a folder (or a `.md` file) onto the window or the Dock icon
- File › Open… (⌘O), or File › Open Recent
- `open -a "Markdown Editor" ~/Notes`

Opening a single `.md` file selects it in place when it is inside the folder already open;
a file from anywhere else opens its own folder with that file selected. The last folder and file
reopen at launch. Files save automatically a second after you stop typing, when you switch files,
and when the window closes or the app quits; ⌘S saves now. There is no "unsaved changes" prompt
while saves succeed. If a save fails (read-only file, disk full), the text stays in the editor, the
title bar says "Not saved", and switching away or quitting asks Keep Editing / Discard Changes.
⌘⇧L toggles the sidebar.

Editing: ⌘B bold, ⌘I italic, ⌘⇧` code, ⌘⇧X strikethrough, ⌘K link, ⌘1–⌘6 heading, ⌘0 paragraph.
Return continues a list, task list or quote (Return on an empty item ends it); Tab / ⇧Tab indent
list items. ⌘-click a link to open it.

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
