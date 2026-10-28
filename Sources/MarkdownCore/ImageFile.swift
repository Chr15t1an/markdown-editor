import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image files the sidebar lists and the viewer shows. Decoding is ImageIO only (no AppKit), so it
/// runs off the main thread and is testable headless.
public enum ImageFile {
    /// Formats ImageIO decodes on macOS 15, compared case-insensitively. No SVG: NSImage draws it only
    /// through a private rep with no pixel size, and ImageIO cannot read it.
    public static let extensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "avif",
    ]

    public static func isImage(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// Header facts, read without decoding pixels. Width and height are as displayed (EXIF
    /// orientation applied).
    public struct Info: Equatable, Sendable {
        public let pixelWidth: Int
        public let pixelHeight: Int
        /// A GIF with more than one frame: the only animation NSImageView plays.
        public let isAnimated: Bool

        public init(pixelWidth: Int, pixelHeight: Int, isAnimated: Bool) {
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.isAnimated = isAnimated
        }

        public var longSide: Int { max(pixelWidth, pixelHeight) }
    }

    /// A decoded bitmap and the file's full-size facts. CGImage is immutable, so it is safe to hand
    /// from the decoding task to the main actor.
    public struct Loaded: @unchecked Sendable {
        public let image: CGImage
        public let info: Info
    }

    public static func info(at url: URL) -> Info? {
        guard let source = makeSource(url),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let turned = (5...8).contains(orientation)   // 90° turns swap width and height
        let isGIF = CGImageSourceGetType(source).map { $0 as String } == UTType.gif.identifier
        return Info(pixelWidth: turned ? height : width, pixelHeight: turned ? width : height,
                    isAnimated: isGIF && CGImageSourceGetCount(source) > 1)
    }

    /// Decodes with the longest side at most `maxPixelSize`, EXIF orientation applied, on the
    /// calling thread.
    public static func thumbnail(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard maxPixelSize > 0, let source = makeSource(url) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,   // never the tiny embedded EXIF thumbnail
            kCGImageSourceCreateThumbnailWithTransform: true,     // orientation (default false)
            kCGImageSourceShouldCacheImmediately: true,           // decode here, not at first draw
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Header facts plus a bitmap no larger than `maxPixelSize`, and never larger than the file.
    public static func load(_ url: URL, maxPixelSize: Int) -> Loaded? {
        guard let info = info(at: url),
              let image = thumbnail(at: url, maxPixelSize: min(maxPixelSize, info.longSide)) else { return nil }
        return Loaded(image: image, info: info)
    }

    /// The scale that fits `size` inside `bounds`, never above 1 (images are never upscaled).
    public static func fitScale(_ size: CGSize, in bounds: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
        return min(1, bounds.width / size.width, bounds.height / size.height)
    }

    /// The bitmap long side needed to draw `info` at `magnification` (1 = one image pixel per point)
    /// on a display with `backingScale`. Never more than the file has, never below 1.
    public static func pixelSize(for info: Info, magnification: CGFloat, backingScale: CGFloat) -> Int {
        let wanted = (CGFloat(info.longSide) * magnification * backingScale).rounded(.up)
        return max(1, min(info.longSide, Int(wanted)))
    }

    /// Window subtitle while an image is shown: "name — W × H".
    public static func subtitle(name: String, info: Info) -> String {
        "\(name) — \(info.pixelWidth) × \(info.pixelHeight)"
    }

    private static func makeSource(_ url: URL) -> CGImageSource? {
        CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    }
}
