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
    private func makeViewer() -> ImageViewer {
        let v = ImageViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
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
}
