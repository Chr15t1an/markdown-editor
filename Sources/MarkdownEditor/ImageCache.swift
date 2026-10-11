import AppKit
import MarkdownCore

/// Loads local images for image-only paragraphs, off the main queue, and sizes them for the
/// text column. Remote (http/https) images are never fetched — no network without a reason.
@MainActor
final class ImageCache {
    private var images: [URL: NSImage] = [:]
    private var missing: Set<URL> = []
    private var loading: Set<URL> = []
    /// Called on the main queue after an image finishes loading.
    var onLoad: ((URL) -> Void)?

    /// The file an image source points at, or nil for remote / unusable sources.
    static func resolve(_ source: String, relativeTo base: URL?) -> URL? {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            return scheme == "file" ? url.standardizedFileURL : nil
        }
        let path = trimmed.removingPercentEncoding ?? trimmed
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        if path.hasPrefix("~") { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL }
        guard let base else { return nil }
        let folder = URL(fileURLWithPath: base.path, isDirectory: true)   // resolve inside, not beside
        return URL(fileURLWithPath: path, relativeTo: folder).standardizedFileURL
    }

    /// Fits `size` to `width` (never upscaling) and caps the height at `maxHeight`.
    static func scaledSize(_ size: NSSize, toWidth width: CGFloat,
                           maxHeight: CGFloat = Theme().imageMaxHeight) -> NSSize {
        guard size.width > 0, size.height > 0, width > 0 else { return .zero }
        var scale = min(1, width / size.width)
        if size.height * scale > maxHeight { scale = maxHeight / size.height }
        return NSSize(width: floor(size.width * scale), height: floor(size.height * scale))
    }

    /// The cached image, or nil; a miss starts a background load (unless the file is missing).
    func image(for url: URL) -> NSImage? {
        if let image = images[url] { return image }
        guard !missing.contains(url), !loading.contains(url) else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { missing.insert(url); return nil }
        loading.insert(url)
        Task.detached(priority: .userInitiated) {
            let data = try? Data(contentsOf: url)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.loading.remove(url)
                if let data, let image = NSImage(data: data) { self.images[url] = image } else { self.missing.insert(url) }
                self.onLoad?(url)
            }
        }
        return nil
    }

    /// Loads synchronously (tests).
    func preload(_ url: URL) {
        if let data = try? Data(contentsOf: url), let image = NSImage(data: data) { images[url] = image }
    }

    /// Pixel-accurate size for layout (NSImage.size can be in points from DPI metadata).
    static func size(of image: NSImage) -> NSSize {
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image.size
    }
}
