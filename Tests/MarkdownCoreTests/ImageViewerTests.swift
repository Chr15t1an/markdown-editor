import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import MarkdownCore
@testable import MarkdownEditor

/// Writes a solid-colour image of `width`×`height` pixels, generated in the test (no binary fixtures).
/// `orientation` is the EXIF/TIFF orientation stored in the file; `frames` > 1 makes a multi-frame file.
func writeTestImage(_ url: URL, width: Int, height: Int, type: UTType = .png,
                    orientation: Int? = nil, frames: Int = 1) throws {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw CocoaError(.fileWriteUnknown)
    }
    ctx.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, frames, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    var props: [CFString: Any] = [:]
    if let orientation {
        props[kCGImagePropertyOrientation] = orientation
        props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFOrientation: orientation]
    }
    if frames > 1, type == .gif {
        props[kCGImagePropertyGIFDictionary] = [kCGImagePropertyGIFDelayTime: 0.1]
    }
    for _ in 0..<frames { CGImageDestinationAddImage(dest, image, props as CFDictionary) }
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}

final class ImageFileTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws { dir = try fixtureDirectory("imagefile") }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func info(_ w: Int, _ h: Int) -> ImageFile.Info {
        ImageFile.Info(pixelWidth: w, pixelHeight: h, isAnimated: false)
    }

    func testThumbnailIsOrientedAndDownsampled() throws {
        let url = dir.appendingPathComponent("turned.jpg")
        try writeTestImage(url, width: 400, height: 200, type: .jpeg, orientation: 6)
        let info = ImageFile.info(at: url)
        XCTAssertEqual(info?.pixelWidth, 200, "displayed width (orientation 6 turns the image)")
        XCTAssertEqual(info?.pixelHeight, 400)
        guard let loaded = ImageFile.load(url, maxPixelSize: 100) else { XCTFail("no thumbnail"); return }
        XCTAssertLessThan(max(loaded.image.width, loaded.image.height), 101)
        XCTAssertGreaterThan(loaded.image.height, loaded.image.width, "orientation applied to the pixels")
        XCTAssertEqual(loaded.info.longSide, 400, "the file's full size is still reported")
    }

    func testLargeImageDecodesAtRequestedSizeOnly() throws {
        let url = dir.appendingPathComponent("big.png")
        try writeTestImage(url, width: 3000, height: 2000)
        guard let small = ImageFile.load(url, maxPixelSize: 512) else { XCTFail("no thumbnail"); return }
        XCTAssertLessThan(max(small.image.width, small.image.height), 513)
        XCTAssertEqual(small.info, info(3000, 2000))
        guard let full = ImageFile.load(url, maxPixelSize: 10_000) else { XCTFail("no full decode"); return }
        XCTAssertEqual(max(full.image.width, full.image.height), 3000, "never upscaled")
    }

    func testAnimatedGIFOnlyCountsAsAnimated() throws {
        let gif2 = dir.appendingPathComponent("two.gif")
        let gif1 = dir.appendingPathComponent("one.gif")
        let tiff2 = dir.appendingPathComponent("pages.tiff")
        try writeTestImage(gif2, width: 20, height: 10, type: .gif, frames: 2)
        try writeTestImage(gif1, width: 20, height: 10, type: .gif)
        try writeTestImage(tiff2, width: 20, height: 10, type: .tiff, frames: 2)
        XCTAssertEqual(ImageFile.info(at: gif2)?.isAnimated, true)
        XCTAssertEqual(ImageFile.info(at: gif1)?.isAnimated, false)
        XCTAssertEqual(ImageFile.info(at: tiff2)?.isAnimated, false, "a multi-page TIFF is not an animation")
    }

    func testExtensionsAreCaseInsensitiveAndSkipSVG() {
        for name in ["a.PNG", "b.jpeg", "c.HEIC", "d.webp", "e.avif"] {
            XCTAssertTrue(ImageFile.isImage(URL(fileURLWithPath: "/x/\(name)")), name)
        }
        for name in ["f.svg", "g.txt", "h.md"] {
            XCTAssertFalse(ImageFile.isImage(URL(fileURLWithPath: "/x/\(name)")), name)
        }
    }

    func testFitScaleNeverUpscales() {
        XCTAssertEqual(ImageFile.fitScale(CGSize(width: 2000, height: 1000), in: CGSize(width: 400, height: 300)),
                       0.2, accuracy: 0.0001)
        XCTAssertEqual(ImageFile.fitScale(CGSize(width: 100, height: 50), in: CGSize(width: 400, height: 300)), 1)
        XCTAssertEqual(ImageFile.fitScale(CGSize(width: 100, height: 50), in: .zero), 1)
    }

    func testPixelSizeIsCappedByTheFile() {
        let i = info(2000, 1000)
        XCTAssertEqual(ImageFile.pixelSize(for: i, magnification: 0.2, backingScale: 2), 800)
        XCTAssertEqual(ImageFile.pixelSize(for: i, magnification: 4, backingScale: 2), 2000)
        XCTAssertEqual(ImageFile.pixelSize(for: i, magnification: 0.0001, backingScale: 2), 1)
    }

    func testSubtitleShowsPixelSize() {
        XCTAssertEqual(ImageFile.subtitle(name: "a.png", info: info(1920, 1080)), "a.png — 1920 × 1080")
    }
}

/// Collects what `ImageViewer.onLoad` reports.
@MainActor
private final class LoadLog {
    var infos: [ImageFile.Info?] = []
}

@MainActor
final class ImageViewerViewTests: XCTestCase {
    var dir: URL!
    var window: NSWindow!
    override func setUp() async throws { dir = try fixtureDirectory("viewer") }
    override func tearDown() async throws { window?.close(); try? FileManager.default.removeItem(at: dir) }

    /// A 400×300 viewer hosted in a borderless window, laid out (decision 30).
    private func makeViewer(width: CGFloat = 400, height: CGFloat = 300,
                            scrollers: NSScroller.Style? = nil) -> ImageViewer {
        let v = ImageViewer(frame: NSRect(x: 0, y: 0, width: width, height: height))
        if let scrollers { v.scrollView.scrollerStyle = scrollers }
        window = NSWindow(contentRect: v.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = v
        v.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(v.scrollView.contentSize.width, 0, "layout ran")
        return v
    }

    /// Shows `url` and waits for the first `onLoad`.
    private func showAndWait(_ v: ImageViewer, _ url: URL) async -> ImageFile.Info? {
        let loaded = expectation(description: "onLoad")
        let log = LoadLog()
        v.onLoad = { info in log.infos.append(info); loaded.fulfill() }
        v.show(url)
        await fulfillment(of: [loaded], timeout: 5)
        return log.infos.first ?? nil
    }

    func testLargeImageIsFittedAndDecodedAtScreenSize() async throws {
        let url = dir.appendingPathComponent("wide.png")
        try writeTestImage(url, width: 2000, height: 1000)
        let v = makeViewer()
        _ = await showAndWait(v, url)
        // The whole 400×300 pane, not `contentSize`: a legacy scroller (no trackpad on the runner)
        // may still be shown, and a fitted image needs none.
        let expected = ImageFile.fitScale(CGSize(width: 2000, height: 1000), in: v.bounds.size)
        XCTAssertEqual(v.scrollView.magnification, expected, accuracy: 0.001)
        XCTAssertLessThan(expected, 1)
        XCTAssertEqual(v.imageView.frame.size, NSSize(width: 2000, height: 1000))
        XCTAssertEqual(v.info?.pixelWidth, 2000)
        XCTAssertGreaterThan(v.decodedPixelSize, 0)
        XCTAssertLessThan(v.decodedPixelSize, 2000, "decoded at screen size, not the full file")
    }

    func testSmallImageIsNeverUpscaledAndIsCentred() async throws {
        let url = dir.appendingPathComponent("small.png")
        try writeTestImage(url, width: 100, height: 50)
        let v = makeViewer()
        _ = await showAndWait(v, url)
        XCTAssertEqual(v.scrollView.magnification, 1, accuracy: 0.001)
        let clip = v.scrollView.contentView
        let r = clip.constrainBoundsRect(NSRect(origin: .zero, size: clip.bounds.size))
        XCTAssertEqual(r.origin.x, -(clip.bounds.width - 100) / 2, accuracy: 0.5)
        XCTAssertEqual(r.origin.y, -(clip.bounds.height - 50) / 2, accuracy: 0.5)
    }

    /// The image's rect on screen is centred in the visible area of the scroll view (insets off).
    private func assertCentred(_ v: ImageViewer, _ label: String, line: UInt = #line) {
        v.layoutSubtreeIfNeeded()
        let sv = v.scrollView
        let image = v.imageView.convert(v.imageView.bounds, to: sv)
        let insets = sv.contentInsets
        var visible = sv.contentView.frame
        visible.origin.x += insets.left
        visible.size.width -= insets.left + insets.right
        visible.origin.y += sv.isFlipped ? insets.top : insets.bottom
        visible.size.height -= insets.top + insets.bottom
        XCTAssertEqual(image.midX, visible.midX, accuracy: 1, "\(label): horizontally centred", line: line)
        XCTAssertEqual(image.midY, visible.midY, accuracy: 1,
                       "\(label): vertically centred (image \(image), visible \(visible))", line: line)
    }

    /// Walk F1: a 4:3 photo fitted by width in a taller pane sat flush at the bottom, because the
    /// bounds were last centred against a clip frame that changed afterwards.
    func testFittedPhotoIsCentredInThePane() async throws {
        let url = dir.appendingPathComponent("photo.png")
        try writeTestImage(url, width: 4000, height: 3000)
        for style in [NSScroller.Style.legacy, .overlay] {
            let v = makeViewer(width: 410, height: 361, scrollers: style)
            _ = await showAndWait(v, url)
            XCTAssertLessThan(v.scrollView.magnification, 0.2)
            assertCentred(v, "\(style.rawValue) after load")
            window.setContentSize(NSSize(width: 520, height: 470))
            assertCentred(v, "\(style.rawValue) after a resize")
            window.setContentSize(NSSize(width: 300, height: 400))
            assertCentred(v, "\(style.rawValue) after a narrower resize")
            window.close()
        }
    }

    func testUndecodableFileReportsNil() async throws {
        let url = dir.appendingPathComponent("bad.png")
        try "x".write(to: url, atomically: true, encoding: .utf8)
        let v = makeViewer()
        let info = await showAndWait(v, url)
        XCTAssertNil(info)
        XCTAssertNil(v.info)
    }

    func testNewerShowWins() async throws {
        let a = dir.appendingPathComponent("a.png")
        let b = dir.appendingPathComponent("b.png")
        try writeTestImage(a, width: 200, height: 100)
        try writeTestImage(b, width: 300, height: 300)
        let v = makeViewer()
        let log = LoadLog()
        let loaded = expectation(description: "first image shown")
        v.onLoad = { info in
            log.infos.append(info)
            if info != nil { loaded.fulfill() }
        }
        v.show(a)
        v.show(b)
        await fulfillment(of: [loaded], timeout: 5)
        // Give a stale decode of `a` time to arrive (it must be dropped).
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        await fulfillment(of: [settled], timeout: 2)
        let shown = log.infos.compactMap { $0 }
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(shown.first?.pixelWidth, 300)
        XCTAssertEqual(shown.first?.pixelHeight, 300)
        XCTAssertEqual(v.info?.pixelWidth, 300)
        XCTAssertEqual(v.url?.lastPathComponent, "b.png")
    }

    func testANewerShowCancelsTheDecodeInFlight() async throws {
        let a = dir.appendingPathComponent("a.png")
        let b = dir.appendingPathComponent("b.png")
        try writeTestImage(a, width: 3000, height: 2000)
        try writeTestImage(b, width: 300, height: 300)
        let v = makeViewer()
        v.show(a)
        let first = v.decodeTask
        XCTAssertNotNil(first)
        let info = await showAndWait(v, b)
        XCTAssertEqual(first?.isCancelled, true, "the older decode is cancelled, not queued")
        XCTAssertEqual(info?.pixelWidth, 300)
        let current = v.decodeTask
        v.clear()
        XCTAssertNil(v.decodeTask)
        XCTAssertEqual(current?.isCancelled, true, "clear() cancels too")
    }

    func testSmartMagnifyLeavesFitModeSoAResizeKeepsTheZoom() async throws {
        let url = dir.appendingPathComponent("wide.png")
        try writeTestImage(url, width: 2000, height: 1000)
        let v = makeViewer()
        _ = await showAndWait(v, url)
        XCTAssertTrue(v.isFitting)
        v.scrollView.magnification = 1   // where a two-finger double tap zooms to
        v.smartMagnified()
        XCTAssertFalse(v.isFitting)
        window.setContentSize(NSSize(width: 600, height: 400))
        v.layoutSubtreeIfNeeded()
        XCTAssertEqual(v.scrollView.magnification, 1, accuracy: 0.001, "the zoom survives a resize")
        XCTAssertEqual(v.scrollView.onSmartMagnify != nil, true, "the scroll view reports smart magnify")
    }

    func testImageViewIsLabelledWithTheFileName() async throws {
        let url = dir.appendingPathComponent("Sunset.png")
        try writeTestImage(url, width: 10, height: 10)
        let v = makeViewer()
        _ = await showAndWait(v, url)
        XCTAssertEqual(v.imageView.accessibilityLabel(), "Sunset.png")
        v.clear()
        XCTAssertNil(v.imageView.accessibilityLabel())
    }
}

@MainActor
final class ImageViewingTests: XCTestCase {
    var dir: URL!
    var other: URL?
    let defaults = UserDefaults.standard

    override func setUp() async throws {
        dir = try fixtureDirectory("viewing")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "n\n".write(to: dir.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        try writeTestImage(dir.appendingPathComponent("pic.png"), width: 640, height: 480)
        try writeTestImage(dir.appendingPathComponent("sub/deep.png"), width: 32, height: 32)
    }

    override func tearDown() async throws {
        defaults.removeObject(forKey: MainWindowController.lastFolderKey)
        defaults.removeObject(forKey: MainWindowController.lastFileKey)
        try? FileManager.default.removeItem(at: dir)
        if let other { try? FileManager.default.removeItem(at: other) }
    }

    private func url(_ name: String) -> URL { dir.appendingPathComponent(name).standardizedFileURL }
    private func path(_ name: String) -> String { url(name).path }

    func testSelectingAnImageSavesTheNoteAndShowsTheViewer() throws {
        let c = MainWindowController()
        c.open(dir)
        c.open(url("note.md"))
        let tv = c.editor.textView!
        tv.insertText("more", replacementRange: NSRange(location: (c.editor.text as NSString).length, length: 0))
        c.sidebar.reveal(url("pic.png"))
        c.sidebar.onSelectFile?(url("pic.png"))
        XCTAssertNil(c.session.currentURL)
        XCTAssertEqual(c.viewedImage?.path, path("pic.png"))
        XCTAssertTrue(c.editor.isShowingImage)
        XCTAssertEqual(try String(contentsOf: url("note.md"), encoding: .utf8), "n\nmore")
        XCTAssertEqual(c.sidebar.selectedFile?.path, path("pic.png"))

        c.sidebar.onSelectFile?(url("note.md"))
        XCTAssertEqual(c.session.currentURL?.path, path("note.md"))
        XCTAssertNil(c.viewedImage)
        XCTAssertFalse(c.editor.isShowingImage)
        c.session.close()
    }

    func testRelaunchRestoresAnImage() {
        defaults.set(dir.path, forKey: MainWindowController.lastFolderKey)
        defaults.set(path("pic.png"), forKey: MainWindowController.lastFileKey)
        let c = MainWindowController()
        c.restoreLastSession()
        XCTAssertEqual(c.viewedImage?.path, path("pic.png"))
        XCTAssertEqual(c.sidebar.selectedFile?.path, path("pic.png"))
        XCTAssertNil(c.session.currentURL)
        XCTAssertTrue(c.editor.isShowingImage)
    }

    func testOpeningAnImageFromOutsideRootsItsFolder() throws {
        let c = MainWindowController()
        c.open(dir)
        XCTAssertTrue(c.open(url("sub/deep.png")))
        XCTAssertEqual(c.folder?.path, dir.standardizedFileURL.path, "sub is inside the root: the root stays")
        XCTAssertEqual(c.viewedImage?.path, path("sub/deep.png"))

        let elsewhere = try fixtureDirectory("viewing-other")
        other = elsewhere
        let o = elsewhere.appendingPathComponent("o.png")
        try writeTestImage(o, width: 10, height: 10)
        XCTAssertTrue(c.open(o))
        XCTAssertEqual(c.folder?.path, elsewhere.standardizedFileURL.path)
        XCTAssertEqual(c.viewedImage?.path, o.standardizedFileURL.path)
    }

    func testDeletedImageShowsTheEmptyState() throws {
        let c = MainWindowController()
        c.open(url("pic.png"))
        XCTAssertEqual(c.viewedImage?.path, path("pic.png"))
        try FileManager.default.removeItem(at: url("pic.png"))
        c.viewedImageMayHaveChanged([path("pic.png")])
        XCTAssertNil(c.viewedImage)
        XCTAssertFalse(c.editor.isShowingImage)
        XCTAssertNil(c.sidebar.selectedFile)
        XCTAssertNil(defaults.string(forKey: MainWindowController.lastFileKey))
    }

    func testNewNoteWithAnImageSelectedGoesInItsFolder() {
        let c = MainWindowController()
        c.open(dir)
        c.open(url("sub/deep.png"))
        c.newNote()
        XCTAssertEqual(c.session.currentURL?.path, path("sub/Untitled.md"))
        XCTAssertFalse(c.editor.isShowingImage)
        c.session.close()
    }

    func testNewNoteFromAnImagePutsTheCursorInTheNote() {
        let c = MainWindowController()
        c.open(dir)
        c.open(url("pic.png"))
        c.newNote()
        XCTAssertTrue(c.window?.firstResponder === c.editor.textView, "⌘N puts the cursor in the new note")
        c.session.close()
    }

    func testArrowingOntoANoteKeepsSidebarFocus() {
        let c = MainWindowController()
        c.open(dir)
        c.open(url("pic.png"))
        XCTAssertTrue(c.window?.firstResponder === c.sidebar.outlineView, "showing an image focuses the sidebar")
        c.sidebar.selectionByKeys = true
        c.sidebar.onSelectFile?(url("note.md"))
        XCTAssertEqual(c.session.currentURL?.path, path("note.md"))
        XCTAssertTrue(c.window?.firstResponder === c.sidebar.outlineView, "arrowing onto a note keeps sidebar focus")

        c.sidebar.selectionByKeys = false
        c.sidebar.onSelectFile?(url("pic.png"))
        c.sidebar.onSelectFile?(url("note.md"))
        XCTAssertTrue(c.window?.firstResponder === c.editor.textView, "a click still focuses the text")
        c.session.close()
    }

    /// Walk F1 in the real window (titled, full-size content view, split view, default size):
    /// a width-fitted camera photo was flush with the bottom of the pane instead of centred.
    func testFittedPhotoIsCentredInTheMainWindow() throws {
        let photo = url("camera.jpg")
        try writeTestImage(photo, width: 8000, height: 6000, type: .jpeg)
        let c = MainWindowController()
        c.open(dir)
        c.open(photo)
        let v = c.editor.imageViewer
        let deadline = Date().addingTimeInterval(20)
        while v.info == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertNotNil(v.info, "decoded")
        c.window?.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let sv = v.scrollView, clip = sv.contentView
        let image = v.imageView.convert(v.imageView.bounds, to: sv)
        let insets = sv.contentInsets
        var visible = clip.frame
        visible.origin.x += insets.left
        visible.size.width -= insets.left + insets.right
        visible.origin.y += sv.isFlipped ? insets.top : insets.bottom
        visible.size.height -= insets.top + insets.bottom
        print("F1 probe: scroll \(sv.frame) flipped \(sv.isFlipped) insets \(insets) clip \(clip.frame) "
              + "bounds \(clip.bounds) clipFlipped \(clip.isFlipped) doc \(v.imageView.frame) "
              + "mag \(sv.magnification) image \(image) visible \(visible) "
              + "scrollers \(sv.scrollerStyle.rawValue) h \(sv.horizontalScroller?.isHidden ?? true) "
              + "v \(sv.verticalScroller?.isHidden ?? true)")
        let constrained = clip.constrainBoundsRect(clip.bounds)
        print("F1 probe1: clip insets \(clip.contentInsets) auto clip \(clip.automaticallyAdjustsContentInsets) "
              + "auto scroll \(sv.automaticallyAdjustsContentInsets) clip.frame.width \(clip.frame.width)")
        print("F1 probe2: clip class \(type(of: clip)) constrained \(constrained) isFitting \(v.isFitting)")
        (clip as? CenteringClipView)?.recentre()
        print("F1 probe3: after recentre bounds \(clip.bounds)")
        v.fit()
        print("F1 probe4: after fit bounds \(clip.bounds)")
        clip.setBoundsOrigin(constrained.origin)
        print("F1 probe5: after setBoundsOrigin bounds \(clip.bounds)")
        c.window?.layoutIfNeeded()
        print("F1 probe6: after layout bounds \(clip.bounds)")
        XCTAssertLessThan(sv.magnification, 0.2)
        XCTAssertEqual(image.midX, visible.midX, accuracy: 1, "horizontally centred")
        XCTAssertEqual(image.midY, visible.midY, accuracy: 1, "vertically centred")
        c.session.close()
    }

    /// Walk report: Tab from the sidebar moved to the note and also left a tab in it. A real Tab
    /// key event (not the probe's `key tab`, which calls insertTab on the text) must not edit.
    func testTabFromTheSidebarDoesNotEditTheNote() throws {
        let c = MainWindowController()
        c.open(dir)
        c.open(url("pic.png"))
        c.sidebar.selectionByKeys = true
        c.sidebar.onSelectFile?(url("note.md"))
        guard let window = c.window else { XCTFail("no window"); return }
        XCTAssertTrue(window.firstResponder === c.sidebar.outlineView)
        let before = c.editor.text
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let tab = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, characters: "\t",
                                       charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
            window.sendEvent(tab)
        }
        XCTAssertEqual(c.editor.text, before, "Tab only moves focus")
        print("tab-from-sidebar: firstResponder is text view = \(window.firstResponder === c.editor.textView)")
        c.session.close()
    }

    func testSessionRefusesAnImage() {
        let c = MainWindowController()
        c.open(dir)
        XCTAssertFalse(c.session.open(url("pic.png")))
        XCTAssertNil(c.session.currentURL)
    }

    func testSubtitleShowsPixelSizeOnceLoaded() async {
        let c = MainWindowController()
        c.open(dir)
        let loaded = expectation(description: "image decoded")
        let previous = c.editor.onImageLoad
        c.editor.onImageLoad = { info in previous?(info); loaded.fulfill() }
        c.open(url("pic.png"))
        await fulfillment(of: [loaded], timeout: 5)
        XCTAssertEqual(c.window?.subtitle, "pic.png — 640 × 480")
    }
}

final class InfoPlistTests: XCTestCase {
    func testEveryImageExtensionIsRegisteredAsAnAlternateViewer() throws {
        let plist = URL(fileURLWithPath: #filePath)   // Tests/MarkdownCoreTests/<file>, three levels below the repo
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plist)
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let types = root["CFBundleDocumentTypes"] as? [[String: Any]],
              let image = types.first(where: { $0["CFBundleTypeName"] as? String == "Image" }) else {
            XCTFail("no Image document type in \(plist.path)")
            return
        }
        XCTAssertEqual(image["CFBundleTypeRole"] as? String, "Viewer")
        XCTAssertEqual(image["LSHandlerRank"] as? String, "Alternate", "Preview stays the default")
        let listed = (image["LSItemContentTypes"] as? [String] ?? []).compactMap { UTType($0) }
        XCTAssertFalse(listed.isEmpty)
        for ext in ImageFile.extensions.sorted() {
            guard let type = UTType(filenameExtension: ext) else { XCTFail("\(ext): no UTType"); continue }
            XCTAssertTrue(listed.contains { type.conforms(to: $0) },
                          "\(ext) → \(type.identifier) is not covered by the Image document type")
        }
    }
}
