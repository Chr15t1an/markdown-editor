---
date: 2026-10-28T01:12:00+00:00
git_commit: 8d52dc5
branch: claude/charming-meitner-k9m397
repository: chr15t1an/markdown-editor
topic: "Image viewing in the folder sidebar"
tags: [research, codebase, sidebar, folder-tree, file-session, image-cache, imageio, appkit]
status: complete
last_updated: 2026-10-28
---

# Research: Image viewing in the folder sidebar

**Date**: 2026-10-28T01:12Z
**Git Commit**: 8d52dc5
**Branch**: claude/charming-meitner-k9m397
**Repository**: chr15t1an/markdown-editor

Sub-agent reports (full detail and every link) are in `research/codebase-map.md` and `research/macos-image-display.md`. They are in the working copy only and git-excluded. Nothing was built or run on a Mac: the session is Linux with no `swift` (`which swift swiftc` → nothing).

## Task Being Researched
List the image files in an opened folder in the sidebar, and show the selected image read-only in the detail pane. The definition is `image-viewer-task-definition.md`.

## Summary
**What exists today.** Four places hard-code markdown-only:
- the folder listing (`FolderTree.swift:77`)
- open resolution (`FolderTree.swift:100`), which every open path goes through: drop, Dock, Finder, Open panel and restore
- session restore (`MainWindowController.swift:212`)
- the Open panel content types (`AppDelegate.swift:91`)

The detail pane is a single, fixed `EditorViewController` split item. Nothing swaps it.

Every sidebar selection goes to `FileSession.open`. That function **reads the file as text before doing anything else** (`FileSession.swift:75`, `FileStore.readCoordinated`). Any image that reached that path would either fail to read (alert sheet) or be decoded as text into the editor, where autosave could write it back.

The Format and Find menu actions are implemented only on `MarkdownTextView`. File › Save, New and Open go to `AppDelegate`, and its `validateMenuItem` always enables them.

**What can be reused.**
- `ImageCache` already loads local images off the main actor. It sizes them by pixel dimensions and never upscales. It decodes the whole file with `NSImage(data:)`, keeps everything forever in an unbounded dictionary, and uses no ImageIO.
- `FolderWatcher` already reloads loaded directories on any FSEvent. Image files would show up live once `list()` allows them.
- `FileSession.close()` leaves a clean "nothing open" state. Note → close → note is already safe.
- `fileClosedExternally` shows the "Select a file" empty state, deselects the sidebar row and clears the subtitle.
- `ProbeLog` is a defaults-gated JSON state dump plus a command file. It can drive selection (`row`), but it has no key for what the detail pane shows.

**What outside sources say.**
- ImageIO on macOS 15 decodes PNG, JPEG, GIF, HEIC (10.15+), WebP (11+), AVIF (13+) and TIFF. It decodes JPEG XL from 14+, according to secondary sources.
- SVG through `NSImage(data:)` works on macOS 14 and 15, but only through a private, undocumented `_NSSVGImageRep` that reports 0×0 pixels.
- EPS stopped loading in NSImage as of macOS 14. PDF does not conform to `public.image`.
- Memory scales with pixel count: a 50 MP image is about 200 MB decoded. `NSImage(contentsOf:)` decodes lazily on the main thread at first draw.
- Downsampling with `CGImageSourceCreateThumbnailAtIndex` needs three things: `…FromImageAlways`, `…WithTransform` (EXIF orientation, default false) and `MaxPixelSize` in pixels.
- A downsampled CGImage does not animate. Apple documents `NSImageView.animates` for GIF only.
- Zoom: `NSScrollView` (`allowsMagnification`, default max 4×) plus a centring `NSClipView` (`constrainBoundsRect`) is Apple's sample pattern (Exhibition, PhotoEditor) and also JXLook's.
- `LSHandlerRank` Alternate lists the app under Open With without making it the default.

## Codebase Findings (Lens 1)

### Folder tree and open resolution
- `FolderTree.markdownExtensions = ["md", "markdown"]`. `isMarkdown` compares extensions case-insensitively (`Sources/MarkdownCore/FolderTree.swift:3-10`).
- `FileNode` has `url`, `isDirectory`, a weak `parent`, and lazy `children` (`:13-27`). It has no file-kind field.
- `list(reusing:)` (`:66-92`):
  - skips hidden files
  - treats packages as files
  - `:77` `guard isDir || FolderTree.isMarkdown(childURL) else { continue }`
  - sorts folders first, then names with `localizedStandardCompare`
  - reuses existing nodes on reload
- `OpenTarget.resolve` (`:95-102`) returns `(folder, nil)` for a directory and `(parent, file)` for markdown (`:100`), and nil for anything else.
- Callers of `isMarkdown` and `resolve`:
  - `MainWindowController.swift:93` (every open), `:179` (Save panel), `:207`/`:212` (restore)
  - `AppDelegate.swift:91` (Open panel)
  - `DropView.swift:34` (drag filter, also reached from `MarkdownTextView.swift:104-114`)
  - `FolderTreeTests.swift:70-79`

### Detail pane and window
- `MainWindowController.swift:33-41`: `NSSplitViewItem(sidebarWithViewController:)` plus `NSSplitViewItem(viewController: editor)`. `editor` is a `let` that `FileSession` also captures (`:12-13`).
- `:43-53`: the split view sits inside a `DropView`, which is the view of a plain root `NSViewController` set as `contentViewController`. Nothing calls `insertSplitViewItem` or `removeSplitViewItem`.
- `EditorViewController.swift:78-89`: a container view holding a pinned scroll view (`MarkdownTextView`) and a centred `emptyLabel`.
- `showEmpty` (`:122-126`) hides the scroll view and shows the label. It does not clear the text, undo or image cache.
- `updateSubtitle()` (`MainWindowController.swift:226-233`) is driven entirely by `session.currentURL` and `session.lastSaveError`.
- Force-unwraps of `editor.textView!`: `MainWindowController.swift:274`, `:295` (probe), and `FileSession.swift:114`, `:243`.

### FileSession
- `open` (`FileSession.swift:69-93`):
  1. If the URL equals `currentURL`, return true.
  2. Read as text (`:75`, via `FileStore.readCoordinated` → encoding guessing at `FileStore.swift:15-22`). On failure, call `onReadFailure`, which shows an alert sheet and re-selects the previous row (`MainWindowController.swift:73-80`).
  3. `prepareToLeave`, then `detach`, then `editor.load`, then `addFilePresenter`.
- `close()` (`:96-101`) is `prepareToLeave` + `forget()` (`:118-125`). Afterwards the URL is nil, nothing is dirty, there is no timer and the presenter is removed. Later `save`, `close` and `prepareToLeave` return true (`:150`). Edits do not mark the file dirty (`:136`).
- Each of these ends in `closeExternally` → `fileClosedExternally` (`MainWindowController.swift:258-263`):
  - coordinated delete (`:200-205`)
  - uncoordinated delete (`:230-233`)
  - save onto a deleted file (`:163-170`)
- A rename goes to `handleMove` (`:207-216`) → `onMoved`. A move to the Trash closes the file.

### Menus and responder chain
- All menu items have a nil target (`MainMenu.swift`).
- New, Open and Save go to `AppDelegate` (`AppDelegate.swift:84-97`). `validateMenuItem` (`:113-120`) returns true for everything except the update items.
- The Format actions exist only on `MarkdownTextView` (`MarkdownTextView.swift:5-13`, `:66-77`).
- Find uses `NSTextView.performFindPanelAction` (`MainMenu.swift:80-95`). With the text view out of the responder chain, menu autoenable disables these items.
- Toggle Sidebar goes to the split view controller (`MainMenu.swift:120`).

### Sidebar and watcher
- `SidebarViewController.swift:188-191`: on selection change, if `!isRevealing` and the row is a file, it calls `onSelectFile` → `MainWindowController.openFile` (`:127-138`) → `session.open`.
- `reveal`, `selectFile` and `refresh` suppress the callback with `isRevealing` (`:49-94`).
- Cell icons are chosen at `:162-164` (`folder`/`doc.text`, labelled "Markdown file"). The width comes from `theme.sidebarIconSize` (`:180`).
- `FolderWatcher.swift:10-28`: FSEvents, per-file events, 0.3 s latency, no filtering.
- `filesChanged` (`SidebarViewController.swift:104-128`) reloads loaded directories and then re-reveals the previous selection. A deleted or renamed selection is not found, and nothing selects the new name.

### Inline image loading (ImageCache)
- `ImageCache.swift:14-28` `resolve` handles relative, absolute, `~` and `file://` paths. Remote URLs give nil.
- `:30-36` `scaledSize` never upscales and caps height at `imageMaxHeight` (480).
- `:39-54` loads with `Task.detached { Data(contentsOf:) }`, then `NSImage(data:)` on the main actor. The cache is an unbounded `[URL: NSImage]`, and `missing` is never cleared.
- `:62-67` `size(of:)` uses the first representation's pixel size.
- Used by `EditorViewController.swift:195-218`, `MarkdownStyler.swift:240-251` and `EditorLayoutManager.swift:48-59`.
- `grep` finds no `CGImageSource` or ImageIO anywhere in `Sources/`.

### Persistence, plist, entry points
- Session restore: `MainWindowController.swift:204-217`. It reads `lastFolderKey` and `lastFileKey`, and accepts the file only if it is inside the folder, is markdown and exists.
- `AppDelegate.swift:61-69` `application(_:open:)` queues URLs until launch finishes, then calls `controller.open`. A non-resolvable URL returns false silently.
- `Resources/Info.plist:9-39` `CFBundleDocumentTypes`:
  - `public.folder`: Viewer / Alternate
  - md and markdown (`net.daringfireball.markdown`): Editor / Alternate
  - no `UTImportedTypeDeclarations`
- The app is not sandboxed. There are no entitlements files, and `scripts/make-app.sh:73-90` signs with no `--entitlements`. Reading sibling images in a folder needs no security-scoped access.

### Theme and DESIGN.md constraints
- Tokens that fit a viewer:
  - `Theme.backgroundColor` (`Theme.swift:67`)
  - `emptyStateColor` and `emptyStateFont` (`:76`, `:80`)
  - sidebar icon size, gap and inset 16/6/2 (`:58-60`)
  - `editorMinWidth` (`:57`)
- There is no viewer or zoom token. `imageMaxHeight` (`:30`) is a document-column rule.
- `DESIGN.md:99` and `:330-331` say "folder and doc.text … No other icons exist."
- `DESIGN.md:10` and `:116` say the app is one `.md` file at a time.
- `DESIGN.md:412-420` describes the sidebar component, and `:430-433` gives the empty-state copy.
- Rules:
  - New values go into `Theme.swift` and the front matter first (`:451-452`).
  - No token for a value used once (`:471`, `:272-273`).
  - No custom motion (`:93-95`).
  - The README scope line is a design rule (`:467-468`).

### Tests
- Three assertions encode markdown-only:
  - `FolderTreeTests.swift:33`: `c.txt` is absent from the listing.
  - `:57`: `node(for: c.txt)` is nil.
  - `:78`: `OpenTarget.resolve(x.txt)` is nil.
- `FileSessionTests` uses only `.md` fixtures.
- `scripts/test.sh` runs `swift test` with Xcode, or a CLT shim. `gen-registry.py` finds new `func test*` automatically.
- `scripts/known-test-failures.txt:8-12` already allowlists `OpenTargetTests.testResolve` and three restore tests (the macOS 26 trailing-slash issue). `check-test-failures.sh` fails only on failures that are not allowlisted.

## Existing Systems & Reuse Opportunities (Lens 2)

### ImageCache (`Sources/MarkdownEditor/ImageCache.swift`)
- **What it is:** an async loader and size helper for inline markdown images.
- **What it serves today:** image-only paragraphs in the editor (styler, layout manager).
- **Relevance:** it is the app's only image-loading code.
  - It decodes the whole file through `NSImage(data:)` on the main actor, with no downsampling, no eviction and no EXIF transform.
  - `scaledSize` encodes the never-upscale rule a viewer's fit would share.
  - Its 480 pt height cap is specific to the document column.

### FileSession close semantics
- **What it is:** the markdown file lifecycle (read, autosave, conflict, presenter).
- **Relevance:** `close()` already gives the "save or prompt, then nothing open" behaviour the definition needs before showing a non-markdown item. `open()` itself cannot accept a binary file without a text read.

### fileClosedExternally / showEmpty
- **What it is:** the existing "the open item went away" path. It shows the empty label, deselects the row, clears the subtitle and removes `lastFileKey`.
- **Relevance:** it is the pattern for "the item being viewed was deleted".

### FolderWatcher + FileNode.reload
- **Relevance:** the live refresh is file-type agnostic. Only `list()` filters.

### OpenTarget.resolve
- **Relevance:** it is the single choke point for drop, Dock, Finder, panel and restore. Widening its predicate widens every entry point at once, including `DropView`'s drag acceptance.

### ProbeLog (`Sources/MarkdownEditor/ProbeLog.swift`, `MainWindowController.swift:273-336`)
- **Relevance:** it can select rows and snapshot state for an on-device walk. `probeState` would need a key for the detail mode to assert on it.

### Existing patterns for similar features
- Empty state: `EditorViewController.showEmpty` (a hidden/visible toggle in one container).
- Off-main loading with a main-actor callback: `ImageCache.image(for:)` plus `onLoad`.
- The suppression flag around programmatic selection: `isRevealing`.

## External Best Practices & Approaches (Lens 3)

### Industry approaches
- **Display stack:** `NSScrollView` (`allowsMagnification`) → centring `NSClipView` → `NSImageView` (or a custom layer-backed view). This is Apple's Exhibition `CenteringClipView`, PhotoEditor `CanvasClipView` and JXLook's `CenterClipView`.
- **Large images:** ImageIO `CGImageSourceCreateThumbnailAtIndex`, with:
  - `kCGImageSourceThumbnailMaxPixelSize` = view points × backing scale
  - `kCGImageSourceCreateThumbnailFromImageAlways` = true, which avoids the tiny embedded EXIF thumbnail
  - `kCGImageSourceCreateThumbnailWithTransform` = true, which applies EXIF orientation
  - `kCGImageSourceShouldCacheImmediately` = true, so the decode happens on the background thread
- FlowVision downsamples at fit size and re-decodes at the new size when a pinch ends.
- **Cheap metadata:** `CGImageSourceCopyPropertiesAtIndex` returns `PixelWidth`, `PixelHeight` and `Orientation`. Swap width and height for orientations 5–8.
- **Animation:** `NSImageView.animates` (default true) plays GIFs loaded as `NSImage(contentsOf:)`. APNG and animated WebP are not documented for NSImageView. `CGAnimateImageAtURLWithBlock` (10.15+) documents GIF and APNG. iMonet uses a custom CGImageSource frame animator for GIF, APNG and WebP.
- **Type checks:** an extension allow-list vs `UTType(filenameExtension:)?.conforms(to: .image)` vs `CGImageSourceCopyTypeIdentifiers()`.
  - A UTType check admits RAW, PSD and third-party types the OS may not decode.
  - Apple notes that extensions do not always determine a file's type.

### Format support on macOS 15
| Format | Status | Source |
|---|---|---|
| PNG, JPEG, TIFF, BMP, GIF | ImageIO baseline | Apple ImageIO docs |
| HEIC/HEIF | macOS 10.15+ | `kCGImagePropertyHEICSDictionary` |
| WebP | macOS 11+ (decode) | `kCGImagePropertyWebPDictionary` |
| AVIF | macOS 13+ | `kCGImagePropertyAVISDictionary` |
| JPEG XL | macOS 14+, still only (secondary sources) | WWDC23 10122, SDWebImageJPEGXLCoder |
| SVG | Works via private `_NSSVGImageRep`, 0×0 pixels, undocumented | Apple forum 740218 |
| EPS | NSImage returns nil since macOS 14 | AppKit 14 release notes |
| PDF | Not `public.image`; ImageIO renders page 1 at 72 dpi | UTType.pdf docs |

### Known pitfalls
- Downsampled photos come out sideways unless `…WithTransform` is set.
- Colour profiles are lost when redrawing through an 8-bit context.
- `NSImage` is not thread-safe, but it can be built on a background thread and handed to the main thread.
- `NSImageRep.size` is in points and follows the file's DPI, so a 300 dpi scan looks small at "100%".
- HDR and gain-map photos display as SDR unless decoded with `kCGImageSourceDecodeToHDR` and shown with `preferredImageDynamicRange` (macOS 14+).
- Multi-page TIFFs and HEIC bursts also have a frame count above 1. The frame count alone does not mean animation.
- `NSFilePresenter` sees only coordinated writes. FSEvents (already used here) sees all writes.

### Sources
- ImageIO thumbnail keys: https://developer.apple.com/documentation/imageio/kcgimagesourcethumbnailmaxpixelsize , …/kcgimagesourcecreatethumbnailfromimagealways , …/kcgimagesourcecreatethumbnailwithtransform , …/kcgimagesourceshouldcacheimmediately
- WWDC18 image best practices (quoted): https://developer.apple.com/forums/thread/109445
- WebP / AVIF / HEIC dictionaries: https://developer.apple.com/documentation/imageio/kcgimagepropertywebpdictionary , …/kcgimagepropertyavisdictionary , …/kcgimagepropertyheicsdictionary
- SVG in NSImage: https://developer.apple.com/forums/thread/740218
- EPS removal: https://developer.apple.com/documentation/macos-release-notes/appkit-release-notes-for-macos-14
- NSImageView.animates: https://developer.apple.com/documentation/appkit/nsimageview/animates
- CGAnimateImageAtURLWithBlock: https://developer.apple.com/documentation/imageio/cganimateimageaturlwithblock(_:_:_:)
- NSScrollView magnification: https://developer.apple.com/documentation/appkit/nsscrollview/allowsmagnification , …/magnify(tofit:)
- Centring clip view: https://developer.apple.com/library/archive/samplecode/PhotoEditor/Listings/Photo_Editor_CanvasClipView_swift.html , https://github.com/yllan/JXLook/blob/28228c0307cf04c539ce1e549738989f66c96222/JXLook/CenterClipView.swift
- FlowVision downsampling: https://github.com/netdcy/FlowVision/blob/a2e6b26fdaa42e09f6b1dbe559da49358a547d41/FlowVision/Sources/Common/ImageProcess.swift#L1088-L1125
- iMonet animator: https://github.com/wflixu/iMonet/blob/878bf696f7103020ff0ceabab1356668b49f2086/Sources/Animator/ImageAnimator.swift
- Info.plist roles and ranks: https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CoreFoundationKeys.html
- application(_:open:): https://developer.apple.com/documentation/appkit/nsapplicationdelegate/application(_:open:)
- HDR: https://developer.apple.com/videos/play/wwdc2023/10181/ , https://developer.apple.com/documentation/appkit/nsimageview/preferredimagedynamicrange
- Full list with more: `research/macos-image-display.md`

## Historical Context (Lens 4)
- The repo has 13 commits. Commits touching the affected files:
  - `a2b85b0` 2026-09-29: initial editor, which drops a folder to open it
  - `5c1bd5a` 2026-10-08: File › New (⌘N)
  - `15c149f` 2026-10-10: 0.3.1, table and display fixes plus a marker reveal fix
  - `e1448cd` 2026-10-10: tokens moved into `Theme.swift`
- There is no prior image-viewer, sidebar-filter or grid work in any branch or commit.
- `CHANGELOG.md:65` mentions only inline images.
- The README scope rule (`README.md:13`) and `DESIGN.md:467-468` make the feature conditional on being missed. The reporter has now said it is.
- Known constraint: the macOS 26 trailing-slash issue already allowlists `OpenTargetTests.testResolve` and the restore tests (`known-test-failures.txt:8-12`). Those are the tests this feature extends.
- Not searched: the documentation KB (`~/Documents/GitHub/documentation` does not exist in this container), quarry and Slack.

## Reproduction (Lens 5 — bugs only)
N/A (not a bug).

## Code References
- `Sources/MarkdownCore/FolderTree.swift:3-10`: `markdownExtensions`, `isMarkdown`
- `Sources/MarkdownCore/FolderTree.swift:77`: listing filter
- `Sources/MarkdownCore/FolderTree.swift:95-102`: `OpenTarget.resolve` (markdown check `:100`)
- `Sources/MarkdownEditor/MainWindowController.swift:33-53`: split view and DropView construction
- `Sources/MarkdownEditor/MainWindowController.swift:92-138`: `open`, `setFolder`, `openFile`
- `Sources/MarkdownEditor/MainWindowController.swift:144-166`: `newNote` folder choice
- `Sources/MarkdownEditor/MainWindowController.swift:204-217`: session restore
- `Sources/MarkdownEditor/MainWindowController.swift:226-233`: subtitle
- `Sources/MarkdownEditor/MainWindowController.swift:258-263`: `fileClosedExternally`
- `Sources/MarkdownEditor/MainWindowController.swift:273-336`: probe state and commands
- `Sources/MarkdownEditor/FileSession.swift:69-101`, `:118-125`: open, close, forget
- `Sources/MarkdownEditor/EditorViewController.swift:78-89`, `:122-126`: view hierarchy, `showEmpty`
- `Sources/MarkdownEditor/SidebarViewController.swift:104-128`, `:157-191`: watcher reload, cells, selection
- `Sources/MarkdownEditor/ImageCache.swift:14-67`: resolve, scale, load, size
- `Sources/MarkdownEditor/AppDelegate.swift:61-69`, `:84-120`: open handling, actions, validation
- `Sources/MarkdownEditor/DropView.swift:15`, `:34`: drag registration and filter
- `Sources/MarkdownCore/Theme.swift:30`, `:57-60`, `:67`, `:76`, `:80`: relevant tokens
- `Resources/Info.plist:9-39`: document types
- `Tests/MarkdownCoreTests/FolderTreeTests.swift:33`, `:57`, `:78`: markdown-only assertions
- `scripts/known-test-failures.txt:8-12`: allowlisted resolve and restore failures

## Architecture Documentation
- **Layering:**
  - `MarkdownCore` is pure logic (tree, resolve, scanners, theme) and is testable without a UI.
  - `MarkdownEditor` holds the AppKit controllers.
  - All file-type knowledge currently lives in `MarkdownCore.FolderTree`.
- **One window, one controller.** `MainWindowController` owns the folder root, the session and the routing (`open` → `setFolder`/`openFile`). The sidebar reports selections through closures (`onSelectFile`). It does not know about the session.
- **One session.** `FileSession` owns the only open file and its presenter. "Nothing open" (`currentURL == nil`) is a supported state.
- **Design system.** Platform semantic colours and SF Symbols only. New values go into `Theme.swift` and the `DESIGN.md` front matter together. No custom animation.

## Open Questions
1. How should the detail pane hold two kinds of content? The current wiring is one fixed split item whose `editor` is shared with `FileSession`. The options seen are:
   - a second split item swapped in
   - a container controller
   - a sibling view inside the editor's container

   Which one does the plan choose?
2. Where is the file-kind decision made: `FolderTree` in core, or `MainWindowController.openFile`? `FileSession.open` reads text unconditionally, so no image may reach it.
3. Type detection: an extension allow-list, a UTType `.image` check, or ImageIO's `CGImageSourceCopyTypeIdentifiers()`? Is SVG in or out, given that its NSImage support is private and undocumented?
4. Animated images: GIF only (NSImageView), or also APNG and WebP (custom animator)? How are animated files told apart from multi-page TIFFs?
5. Should viewer decoding share `ImageCache`, given that it has no eviction, decodes the full file and has no EXIF transform? Or is it separate? Does the inline path have the same large-image issue?
6. What does "100%" mean: pixels at backing scale, or the image's DPI-derived point size?
7. While an image is shown, should File › Save stay enabled? `AppDelegate.validateMenuItem` returns true, and with no session `save` returns true and does nothing. What should the Format and Find items do? (Autoenable disables them.)
8. Should `probeState` expose the detail mode for an on-device walk?
9. HDR and gain-map photos: SDR only for v1?
10. Rename of the viewed image: the session's `handleMove` path does not apply to an image. `filesChanged` re-reveals a URL that no longer exists. What should the viewer do?

## Raw Notes
- `FileSession.open` returns true when given the current URL (`:72`). A viewer-to-viewer switch would not touch it.
- `DropView` registers `.fileURL` only and delegates acceptance to `OpenTarget.resolve`, so image drops are accepted automatically once `resolve` accepts images.
- The Save panel at `MainWindowController.swift:179` uses markdown types. It is unaffected by this feature.
- The Open panel (`AppDelegate.swift:91`) lists only folder and markdown types.
- Finder Open With for a non-NSDocument app arrives through `application(_:open:)`, which already exists and queues URLs at launch.
- The task definition's line refs were off by a few lines: the filter is at `:77` (not `:79`) and the resolve check at `:100` (not `:101`). This document uses the correct ones.
