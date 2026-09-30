import AppKit
import XCTest
@testable import MarkdownCore
@testable import MarkdownEditor

@MainActor
final class ImageTests: XCTestCase {
    var dir: URL!

    override func setUp() async throws {
        dir = try fixtureDirectory("images")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 200, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("pic.png"))
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    func testResolve() {
        XCTAssertEqual(ImageCache.resolve("pic.png", relativeTo: dir), dir.appendingPathComponent("pic.png").standardizedFileURL)
        XCTAssertEqual(ImageCache.resolve("../x/my%20pic.png", relativeTo: dir),
                       dir.deletingLastPathComponent().appendingPathComponent("x/my pic.png").standardizedFileURL)
        XCTAssertEqual(ImageCache.resolve("/abs/p.png", relativeTo: dir), URL(fileURLWithPath: "/abs/p.png"))
        XCTAssertEqual(ImageCache.resolve("file:///abs/p.png", relativeTo: dir), URL(fileURLWithPath: "/abs/p.png"))
        XCTAssertNil(ImageCache.resolve("https://example.com/p.png", relativeTo: dir))
        XCTAssertNil(ImageCache.resolve("http://example.com/p.png", relativeTo: dir))
    }

    func testScaledSize() {
        XCTAssertEqual(ImageCache.scaledSize(NSSize(width: 400, height: 200), toWidth: 300), NSSize(width: 300, height: 150))
        XCTAssertEqual(ImageCache.scaledSize(NSSize(width: 100, height: 50), toWidth: 300), NSSize(width: 100, height: 50))
        XCTAssertEqual(ImageCache.scaledSize(NSSize(width: 500, height: 2000), toWidth: 600).height, 480)
    }

    private func editor(_ text: String, width: CGFloat = 300) -> EditorViewController {
        let e = EditorViewController()
        e.loadView()
        e.baseURL = dir
        e.textContainer.size = NSSize(width: width + 2 * e.textContainer.lineFragmentPadding, height: .greatestFiniteMagnitude)
        e.load(text)
        return e
    }

    func testParagraphSpacingForLoadedImage() {
        let e = editor("![x](pic.png)\nafter\n")
        XCTAssertNil(e.textStorage.attribute(.mdImage, at: 0, effectiveRange: nil))  // not loaded yet
        e.images.preload(dir.appendingPathComponent("pic.png").standardizedFileURL)
        e.restyleAll()
        let p = e.textStorage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle
        XCTAssertEqual(p.paragraphSpacing, 150 + 8)
        XCTAssertNotNil(e.textStorage.attribute(.mdImage, at: 0, effectiveRange: nil))
        // Whole source is one span marker: hidden while the caret is elsewhere.
        let reveal = e.textStorage.attribute(.mdMarker, at: 5, effectiveRange: nil) as? MarkerReveal
        XCTAssertEqual(reveal?.scope, .span)
        e.textView.setSelectedRange(NSRange(location: 16, length: 0))
        e.layoutManager.ensureLayout(for: e.textContainer)
        XCTAssertTrue(MarkerHidingLayoutDelegate.isHiddenGlyph(e.layoutManager, character: 5))
        e.textView.setSelectedRange(NSRange(location: 4, length: 0))
        e.layoutManager.ensureLayout(for: e.textContainer)
        XCTAssertFalse(MarkerHidingLayoutDelegate.isHiddenGlyph(e.layoutManager, character: 5))
    }

    func testMissingFileKeepsSourceVisible() {
        let e = editor("![x](nope.png)\nafter\n")
        e.restyleAll()
        XCTAssertNil(e.textStorage.attribute(.mdImage, at: 0, effectiveRange: nil))
        XCTAssertNil(e.textStorage.attribute(.mdMarker, at: 2, effectiveRange: nil))  // alt text not hidden
        let p = e.textStorage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle
        XCTAssertEqual(p.paragraphSpacing, 0)
    }

    func testRemoteImageNotLoaded() {
        let e = editor("![x](https://example.com/p.png)\n")
        e.restyleAll()
        XCTAssertNil(e.textStorage.attribute(.mdImage, at: 0, effectiveRange: nil))
    }

    func testAsyncLoadRestyles() async throws {
        let e = editor("![x](pic.png)\n")
        let loaded = expectation(description: "loaded")
        let previous = e.images.onLoad
        e.images.onLoad = { url in previous?(url); loaded.fulfill() }
        e.restyleAll()   // triggers the background load
        await fulfillment(of: [loaded], timeout: 5)
        XCTAssertNotNil(e.textStorage.attribute(.mdImage, at: 0, effectiveRange: nil))
    }
}
