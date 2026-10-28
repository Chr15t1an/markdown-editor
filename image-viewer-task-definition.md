# Image viewing in the folder sidebar

## TL;DR
**Type:** feature — the app only lists and opens `.md`/`.markdown`; image files in an opened folder are invisible.
**User path:** yes — "Christian drops a folder with one `.md` and a set of images onto the window, sees the images listed in the sidebar next to the note, clicks one and sees it fitted in the right-hand pane, then arrow-keys through the rest."
**Problem:** Image files in an opened folder are filtered out of the sidebar, and there is nowhere to show one.
**Backed by:**
- `FolderTree.swift:77`: `guard isDir || FolderTree.isMarkdown(childURL) else { continue }` drops every non-markdown file from the tree.
- `OpenTarget.resolve` (`FolderTree.swift:100`) returns nil for any non-markdown file, so dropping or opening an image does nothing.
- The detail pane is only ever `EditorViewController` (`MainWindowController.swift:37`). No view displays an image file on its own.

**Status:** verified (code read). Not yet verified: SVG/WebP/HEIC rendering through `NSImage` on macOS 15, and how much memory large images use.
**Ask:** List the images in an opened folder and preview them in the app.
**Why:** Folders of notes often hold the screenshots and photos the note is about. Today you have to switch to Finder or Preview to see them.

## Reported Issue
Christian (2026-10-27, verbal): *"If we're in a folder and it had, say, one markdown file and then a list of images, it'd be cool to be able to preview and list and see those images. How hard is that?"*
He is the only user named. The scenario is a note folder with one `.md` file and its images. Volume: interactive, one user, so no throughput concern. Folder sizes are unknown (see Open Questions).

On 2026-10-28 he delegated the design: *"make good choices then draft the task."*

## Evidence
- **verified:** `Sources/MarkdownCore/FolderTree.swift`
  - `markdownExtensions: Set<String> = ["md", "markdown"]` is the only allow-list.
  - `FileNode` stores only `isDirectory` and has no file kind.
  - `list()` skips hidden files and packages and sorts folders first, then names with `localizedStandardCompare`.
- **verified:** `Sources/MarkdownEditor/SidebarViewController.swift:162-164` picks between two icons only: `folder` and `doc.text` ("Markdown file").
- **verified:** `outlineViewSelectionDidChange` calls `onSelectFile` → `MainWindowController.openFile` → `session.open(url)`. `FileSession` handles markdown files only (load, autosave, conflict).
- **verified:** `MainWindowController.restoreLastSession` (line 212) restores the last file only if `FolderTree.isMarkdown(file)`.
- **verified:** `newNote()` (line 144) picks its folder from `sidebar.selectedDirectory`, then from `session.currentURL`'s parent, then the root. If an image row is selected and no note is open, the new note lands in the root rather than the image's folder.
- **verified:** `updateSubtitle()` shows `session.currentURL`'s name or a "Not saved" error.
- **verified:** `Sources/MarkdownEditor/ImageCache.swift` already loads local images off the main queue for inline `![]()` paragraphs. `scaledSize` never upscales and caps height (`Theme.imageMaxHeight` = 480). It never fetches remote images.
- **verified:** `Resources/Info.plist` `CFBundleDocumentTypes` registers only `public.folder` (Viewer, Alternate), plus markdown types.
- **verified:** `Package.swift` `platforms: [.macOS(.v15)]`, so macOS 15 is the floor.
- **verified:** `README.md:13` says "Anything beyond that … is out of scope until it's actually missed." `DESIGN.md:468` makes that line a design rule. Christian is now reporting that he misses this, which meets the rule. Both docs describe the app as one `.md` at a time and will need updating.
- **verified:** `DESIGN.md` lists the sidebar icons as SF Symbols `folder` and `doc.text` only.
- **verified:** `CLAUDE.md` says to read `DESIGN.md` before any UI change and that tokens live in `Sources/MarkdownCore/Theme.swift`.
- **verified:** Tests: `Tests/MarkdownCoreTests/FolderTreeTests.swift` fixtures include `c.txt` and assert markdown-only listing. `scripts/test.sh` needs macOS (Xcode or the CLT shim). This Linux container has no `swift`, so none of this can be built or run here.
- **Sweep:**
  - git branches: only `main` and `claude/charming-meitner-k9m397`.
  - git log: no prior image, viewer or sidebar-filter work.
  - `CHANGELOG.md` mentions only inline images (`:65`).
  - No existing definition or notes card in either repo.
  - Slack, quarry and the documentation KB were not searched: personal side project, and they are not mounted in this container.

## Reporter's Proposal
No reporter proposal. Christian delegated the choices ("make good choices"). The proposal below is Claude's, and research should validate it. The question-and-answer exchange from 2026-10-27 is folded in.

1. **Sidebar list plus single-image preview. No thumbnail grid in v1.** Arrow keys in the outline view already work as flip-through. A grid (`NSCollectionView`, thumbnail cache, mode toggle) costs about 2–3× as much. Build it only if it's missed (README rule).
2. **Images always shown in the sidebar, no toggle.** Add a "Show images" setting only if image-heavy folders bury the notes in practice.
3. **Formats:** png, jpg/jpeg, gif, heic/heif, webp, tiff/tif, bmp, svg, matched case-insensitively. Drop any format `NSImage` can't render on macOS 15 rather than special-casing it.
4. **Viewer:**
   - Read-only.
   - Fitted to the pane, never upscaled past 100%, centred on the editor background.
   - Pinch-zoom and scroll when zoomed.
   - Animated GIFs play.
   - Large files are downsampled for display instead of decoded at full size.
   - No rotate, crop, delete or edit.
5. **Sidebar icon:** SF Symbol `photo` at the existing 16pt sidebar size. Add it to `DESIGN.md`.
6. **Opening:**
   - Dropping an image, or opening one from the Dock or Finder, opens its parent folder with the image selected. This is the same rule `OpenTarget` applies to `.md`.
   - Register `public.image` in `Info.plist` as Viewer, `LSHandlerRank` **Alternate**, so it appears under Open With without taking over from Preview.
7. **Switching to an image** saves or prompts on the open note exactly as switching notes does today. Unsaved text is never lost.
8. **Session restore** reopens the last selected image the same way it reopens the last note.
9. **Window subtitle** while viewing shows `name — W × H` (pixel size).
10. **⌘N while an image is selected** creates the note in the image's folder.
11. **Docs:** update `README.md` (feature bullet and scope line), `DESIGN.md` (description, icon list, a viewer component entry) and `CHANGELOG.md`.

## Decisions delegated
Delegated to the run (Christian, 2026-10-28, "make good choices"):
- implementation approach
- file and type layout
- names
- viewer visual details within `DESIGN.md`
- the choices in the proposal above

Christian keeps the gate list. The build cannot be run in this container, so he does the on-device check on his Mac.

## Open Questions → Research
1. **Formats:** does `NSImage` on macOS 15 render SVG, WebP and HEIC correctly, including SVGs with no intrinsic size? Any format that fails is dropped from the list (proposal 3).
2. **Large images:** what is the memory and time cost of `NSImageView` on a 50MP JPEG or a 100MB TIFF? At what size should ImageIO thumbnailing take over?
3. **Detail pane:**
   - Where should the swap between editor and viewer live: a container view controller, or replacing the split item's controller?
   - What happens to the find bar, ⌘S, the Format menu items and editor focus while an image is shown? Each should be disabled, not crash.
4. **`FileSession`:** does `session.close()` with no next file leave the session in a clean "nothing open" state? `setFolder` already relies on this, but confirm it for image → note → image sequences.
5. **`FolderWatcher`:** does it refresh for image changes the same way (rename, delete while viewing)? What should the viewer show when the image it displays is deleted? Proposal: the "Select a file" empty state.
6. **Tests:**
   - `FolderTreeTests` fixtures and expectations change because images are now listed. Add image fixtures plus a non-image control file (`c.txt` stays hidden).
   - `testResolve` gains image cases.
   - Is any UI-level probe (`ProbeLog`) needed for the on-device walk?
7. **Volume:** how large do Christian's image folders get? Dozens or thousands? This only matters if the lazy outline view struggles. Research can measure it with a 5,000-file fixture.

## ❓ Open Questions for Christian
❓ **Q1** - **Grid view**: is a sidebar list with one image at a time enough for v1, or is a thumbnail grid the actual want?
➡️ List + preview; the grid becomes its own task if you miss it. *(Draft assumes this, proposal 1.)*

❓ **Q2** - **Default to showing images**: should images always appear in the sidebar, or should they sit behind a setting?
➡️ Always shown, no setting. *(Draft assumes this, proposal 2.)*

❓ **Q3** - **"Open With" registration**: should the app register for images so it appears in Finder's Open With menu (never as the default app)?
➡️ Yes, at Alternate rank. *(Draft assumes this, proposal 6.)*

Next: research-codebase, using the Open Questions as inputs.
