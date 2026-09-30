# Markdown Editor

A native macOS markdown editor that renders formatting inline as you type, and opens any folder you drop on it as a file tree.

## Why this exists

Typora is the right shape for editing markdown — one pane, WYSIWYG, open any folder with no vault setup — but it's paid ($15 after the trial). Obsidian only works on vaults and VS Code treats markdown as raw text plus a preview pane. This is a small, free, native clone that does just the parts that matter:

- Typora-style inline editing: markdown syntax renders in place while you type, no preview toggle.
- Drag a folder onto the window or the Dock icon and it opens to that folder, with a sidebar file tree.

Anything beyond that (themes, export, plugins) is out of scope until it's actually missed. Background on the pick: `documentation/mac-apps/README.md`.

## Running it

Requires macOS 15 and Xcode 16 installed at `/Applications/Xcode.app` (it does not need to be the
selected developer directory — the script and commands below point at it per command).

```sh
scripts/make-app.sh             # build + sign "build/Markdown Editor.app"
scripts/make-app.sh --install   # same, then copy it to /Applications (quits a running copy first)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test   # test suite
```

Open a folder any of these ways; it replaces the one that is open:

- drag a folder (or a `.md` file) onto the window or the Dock icon
- File › Open… (⌘O), or File › Open Recent
- `open -a "Markdown Editor" ~/Documents/GitHub/documentation`

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
