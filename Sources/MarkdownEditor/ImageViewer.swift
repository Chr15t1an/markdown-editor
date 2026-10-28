import AppKit
import MarkdownCore

/// The detail pane for an image file: fitted to the pane and never above 100 % (one image pixel
/// per point), centred on the editor background, pinch to zoom up to AppKit's 4×, scroll when
/// zoomed. Decodes off the main thread at the size on screen, and again sharper after a zoom.
@MainActor
final class ImageViewer: NSView {
    let scrollView = NSScrollView()
    let imageView = NSImageView()
    private(set) var url: URL?
    /// Facts of the image on screen; nil while loading or when it could not be decoded.
    private(set) var info: ImageFile.Info?
    /// Long side, in pixels, of the bitmap on screen (0 while loading).
    private(set) var decodedPixelSize = 0
    private var requestedPixelSize = 0
    /// True until the user pinches: a resize then keeps the image fitted.
    private(set) var isFitting = true
    private var generation = 0
    /// Called on the main queue once a shown image is decoded (nil: it could not be).
    var onLoad: ((ImageFile.Info?) -> Void)?
    var theme = Theme() { didSet { scrollView.backgroundColor = theme.backgroundColor } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.contentView = CenteringClipView()
        scrollView.documentView = imageView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = theme.backgroundColor
        imageView.imageScaling = .scaleAxesIndependently   // the frame carries the aspect ratio
        imageView.animates = true
        imageView.setAccessibilityIdentifier("image-viewer")
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(willStartMagnify(_:)),
                           name: NSScrollView.willStartLiveMagnifyNotification, object: scrollView)
        center.addObserver(self, selector: #selector(didEndMagnify(_:)),
                           name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows `url`: drops the old image at once, then decodes the new one in the background.
    /// Only the newest call's result is ever shown.
    func show(_ url: URL) {
        let url = url.standardizedFileURL
        clear()
        self.url = url
        let gen = generation
        let viewport = availableSize()
        let scale = window?.backingScaleFactor ?? 2
        Task.detached(priority: .userInitiated) {
            guard let info = ImageFile.info(at: url) else {
                await MainActor.run { [weak self] in self?.apply(nil, gif: nil, info: nil, generation: gen) }
                return
            }
            if info.isAnimated {
                let data = try? Data(contentsOf: url)   // NSImage(data:) keeps every GIF frame
                await MainActor.run { [weak self] in self?.apply(nil, gif: data, info: info, generation: gen) }
            } else {
                let fit = ImageFile.fitScale(CGSize(width: info.pixelWidth, height: info.pixelHeight), in: viewport)
                let side = ImageFile.pixelSize(for: info, magnification: fit, backingScale: scale)
                let loaded = ImageFile.load(url, maxPixelSize: side)
                await MainActor.run { [weak self] in self?.apply(loaded, gif: nil, info: info, generation: gen) }
            }
        }
    }

    /// Releases the image (the pane is showing something else).
    func clear() {
        generation += 1
        url = nil
        info = nil
        decodedPixelSize = 0
        requestedPixelSize = 0
        isFitting = true
        imageView.image = nil
    }

    private func apply(_ loaded: ImageFile.Loaded?, gif: Data?, info newInfo: ImageFile.Info?, generation gen: Int) {
        guard gen == generation else { return }   // a newer selection won
        let firstLoad = info == nil
        guard let newInfo else { onLoad?(nil); return }
        let size = NSSize(width: newInfo.pixelWidth, height: newInfo.pixelHeight)
        let image: NSImage
        let side: Int
        if let loaded {
            guard loaded.info.longSide > 0 else { return }
            side = max(loaded.image.width, loaded.image.height)
            guard firstLoad || side > decodedPixelSize else { return }   // never swap in a smaller bitmap
            image = NSImage(cgImage: loaded.image, size: size)
        } else if let gif, let animated = NSImage(data: gif) {
            animated.size = size   // pixel size, not DPI-derived points
            side = newInfo.longSide
            image = animated
        } else {
            if firstLoad { onLoad?(nil) }
            return
        }
        info = newInfo
        decodedPixelSize = side
        imageView.image = image
        if firstLoad {
            imageView.frame = NSRect(origin: .zero, size: size)
            fit()
            onLoad?(newInfo)
        }
    }

    /// Fits the image to the pane (never above 100 %); the clip view centres it.
    func fit() {
        guard let info else { return }
        let scale = ImageFile.fitScale(CGSize(width: info.pixelWidth, height: info.pixelHeight), in: availableSize())
        scrollView.minMagnification = scale
        scrollView.magnification = scale
        isFitting = true
    }

    /// The visible area in points: the scroll view's content size less its insets (the title bar
    /// under a full-size content view). Before the first layout, the window or default size.
    private func availableSize() -> CGSize {
        let insets = scrollView.contentInsets
        let size = scrollView.contentSize
        let available = CGSize(width: size.width - insets.left - insets.right,
                               height: size.height - insets.top - insets.bottom)
        if available.width > 0, available.height > 0 { return available }
        return window?.contentLayoutRect.size ?? theme.defaultWindowSize
    }

    /// Decodes a sharper bitmap when the one on screen has fewer pixels than the zoom needs.
    func refreshResolution() {
        guard let url, let info, !info.isAnimated, decodedPixelSize > 0 else { return }
        let needed = ImageFile.pixelSize(for: info, magnification: scrollView.magnification,
                                         backingScale: window?.backingScaleFactor ?? 2)
        guard needed > max(decodedPixelSize, requestedPixelSize) else { return }
        requestedPixelSize = needed
        let gen = generation
        Task.detached(priority: .userInitiated) {
            let loaded = ImageFile.load(url, maxPixelSize: needed)
            await MainActor.run { [weak self] in self?.apply(loaded, gif: nil, info: info, generation: gen) }
        }
    }

    override func layout() {
        super.layout()
        if isFitting, info != nil { fit(); refreshResolution() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshResolution()
    }

    @objc private func willStartMagnify(_ note: Notification) { isFitting = false }

    @objc private func didEndMagnify(_ note: Notification) {
        if scrollView.magnification <= scrollView.minMagnification + 0.001 { isFitting = true }
        refreshResolution()
    }
}

/// Keeps a document smaller than the visible area centred (Apple's PhotoEditor / Exhibition
/// clip-view pattern), with the scroll view's content insets taken into account.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView?.frame else { return rect }
        let unit = frame.width > 0 ? rect.width / frame.width : 1   // document units per point
        let insets = contentInsets
        let visibleWidth = rect.width - (insets.left + insets.right) * unit
        let visibleHeight = rect.height - (insets.top + insets.bottom) * unit
        if visibleWidth > doc.width {
            rect.origin.x = doc.minX - (visibleWidth - doc.width) / 2 - insets.left * unit
        }
        if visibleHeight > doc.height {
            let lowInset = isFlipped ? insets.top : insets.bottom
            rect.origin.y = doc.minY - (visibleHeight - doc.height) / 2 - lowInset * unit
        }
        return rect
    }
}
