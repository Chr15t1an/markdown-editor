# Markdown Editor

A native macOS markdown editor that renders formatting inline as you type, and opens any folder you drop on it as a file tree.

## Why this exists

Typora is the right shape for editing markdown — one pane, WYSIWYG, open any folder with no vault setup — but it's paid ($15 after the trial). Obsidian only works on vaults and VS Code treats markdown as raw text plus a preview pane. This is a small, free, native clone that does just the parts that matter:

- Typora-style inline editing: markdown syntax renders in place while you type, no preview toggle.
- Drag a folder onto the window or the Dock icon and it opens to that folder, with a sidebar file tree.

Anything beyond that (themes, export, plugins) is out of scope until it's actually missed. Background on the pick: `documentation/mac-apps/README.md`.

## Running it

Not built yet — the stack and first milestone are decided in the build plan.

## Stack

Native macOS (Swift, SwiftUI/AppKit). No Electron, no web view shell.
