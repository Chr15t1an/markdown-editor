import AppKit
import MarkdownCore

/// The editing pane: a TextKit 1 NSTextView in a scroll view, plus an empty-state label.
final class EditorViewController: NSViewController, NSTextViewDelegate, NSTextStorageDelegate {
    static let readableWidth: CGFloat = 760
    static let minimumInset: CGFloat = 28

    let textStorage = NSTextStorage()
    let layoutManager = EditorLayoutManager()
    let hiding = MarkerHidingLayoutDelegate()
    var styler = MarkdownStyler()
    private(set) var document = MarkdownDocument("")
    /// Character range touched by edits since the last restyle (post-edit coordinates).
    private var pendingEdit: NSRange?
    private let undo = UndoManager()
    let images = ImageCache()
    /// Folder of the open file (relative image and link paths resolve against it).
    var baseURL: URL? { didSet { textView?.baseURL = baseURL } }
    let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    private(set) var textView: MarkdownTextView!
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "Drop a folder here")

    /// Called after every user edit.
    var onTextChange: (() -> Void)?
    var onOpen: ((URL) -> Void)? { didSet { textView?.onOpen = onOpen } }

    override func loadView() {
        layoutManager.delegate = hiding
        layoutManager.hiding = hiding
        configureImages()
        textStorage.addLayoutManager(layoutManager)
        textStorage.delegate = self
        layoutManager.addTextContainer(textContainer)
        textContainer.widthTracksTextView = false  // width set in updateInsets (readable column)

        let tv = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: textContainer)
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset = NSSize(width: Self.minimumInset, height: 24)
        tv.font = styler.theme.bodyFont
        tv.defaultParagraphStyle = styler.theme.paragraphStyle()
        tv.typingAttributes = styler.theme.bodyAttributes
        tv.delegate = self
        tv.onOpen = onOpen
        tv.setAccessibilityIdentifier("editor")
        textView = tv

        scrollView.documentView = tv
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.contentView.postsFrameChangedNotifications = true

        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 17)
        emptyLabel.alignment = .center

        let container = NSView()
        for v in [scrollView, emptyLabel] { v.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(v) }
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        view = container
        showEmpty("Drop a folder here")

        NotificationCenter.default.addObserver(
            self, selector: #selector(clipFrameChanged), name: NSView.frameDidChangeNotification,
            object: scrollView.contentView)
    }

    @objc private func clipFrameChanged() { updateInsets() }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateInsets()
    }

    /// Centers a readable column of text in wide windows.
    private func updateInsets() {
        let width = scrollView.contentView.bounds.width
        let horizontal = max(Self.minimumInset, (width - Self.readableWidth) / 2)
        if abs(textView.textContainerInset.width - horizontal) > 0.5 {
            textView.textContainerInset = NSSize(width: horizontal, height: 24)
        }
        let containerWidth = max(100, width - 2 * horizontal)
        if abs(textContainer.size.width - containerWidth) > 0.5 {
            textContainer.size = NSSize(width: containerWidth, height: CGFloat.greatestFiniteMagnitude)
            if hasImages { restyleAll() }   // image heights depend on the column width
        }
    }

    // MARK: Content

    var text: String { textStorage.string }

    func showEmpty(_ message: String) {
        emptyLabel.stringValue = message
        emptyLabel.isHidden = false
        scrollView.isHidden = true
    }

    /// Replaces the whole document (file open / external reload). Not undoable.
    func load(_ text: String, selection: NSRange? = nil) {
        emptyLabel.isHidden = true
        scrollView.isHidden = false
        textStorage.beginEditing()
        textStorage.setAttributedString(NSAttributedString(string: text, attributes: styler.theme.bodyAttributes))
        textStorage.endEditing()
        undo.removeAllActions()
        let length = (text as NSString).length
        let sel = selection.map { NSRange(location: min($0.location, length), length: 0) }
            ?? NSRange(location: 0, length: 0)
        document = MarkdownDocument(text)
        pendingEdit = nil
        styler.styleAll(textStorage, document: document)
        textView.setSelectedRange(sel)
        updateReveal(force: true)
        resetTypingAttributes()
    }

    func focus() { view.window?.makeFirstResponder(textView) }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        restyle()
        onTextChange?()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateReveal()
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    // MARK: NSTextStorageDelegate

    /// Records where the text changed. Styling happens later, in `textDidChange` — restyling
    /// inside processEditing moves the caret.
    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        let length = textStorage.length
        MainActor.assumeIsolated { recordEdit(length, editedRange, delta) }
    }

    private func recordEdit(_ length: Int, _ editedRange: NSRange, _ delta: Int) {
        if let pending = pendingEdit {
            // Shift the old pending range by the new edit when it lies after it.
            var old = pending
            if old.location >= editedRange.location { old.location = max(editedRange.location, old.location + delta) }
            old.length = max(0, min(old.length, length - old.location))
            pendingEdit = NSUnionRange(old, editedRange)
        } else {
            pendingEdit = editedRange
        }
    }

    // MARK: Images

    private var hasImages: Bool { textStorage.length > 0 && textStorage.string.contains("![") }

    /// Width available to an image: the text column minus the line padding.
    var imageWidth: CGFloat { textContainer.size.width - 2 * textContainer.lineFragmentPadding }

    private func configureImages() {
        styler.imageSpacing = { [weak self] info in
            MainActor.assumeIsolated {
                guard let self, let url = ImageCache.resolve(info.source, relativeTo: self.baseURL),
                      let image = self.images.image(for: url) else { return nil }
                return ImageCache.scaledSize(ImageCache.size(of: image), toWidth: self.imageWidth).height + ImageCache.gap
            }
        }
        images.onLoad = { [weak self] _ in self?.restyleAll() }
        layoutManager.drawImage = { [weak self] info, rect in
            MainActor.assumeIsolated {
                guard let self, let url = ImageCache.resolve(info.source, relativeTo: self.baseURL),
                      let image = self.images.image(for: url) else { return }
                let size = ImageCache.scaledSize(ImageCache.size(of: image), toWidth: rect.width)
                let target = NSRect(x: rect.minX, y: rect.minY, width: size.width, height: size.height)
                image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
    }

    /// Restyles the whole document, keeping the selection (image loads, column width changes).
    func restyleAll() {
        guard textStorage.length == document.length, !textView.hasMarkedText() else { return }
        let selection = textView.selectedRanges
        styler.styleAll(textStorage, document: document)
        if textView.selectedRanges != selection { textView.selectedRanges = selection }
        updateReveal(force: true)
    }

    // MARK: Styling

    /// Re-parses and restyles the blocks that changed. Skipped while IME composition is active
    /// (marked text); the commit triggers another textDidChange.
    func restyle() {
        guard !textView.hasMarkedText() else { return }
        let old = document
        let new = MarkdownDocument(textStorage.string)
        document = new
        let edited = pendingEdit ?? NSRange(location: 0, length: 0)
        pendingEdit = nil
        let delta = new.length - old.length
        var range = edited
        if let changed = changedBlocks(old: old, new: new, delta: delta) { range = NSUnionRange(range, changed) }
        range.location = min(range.location, new.length)
        range.length = min(range.length, new.length - range.location)
        let selection = textView.selectedRanges
        styler.style(textStorage, document: new, in: range)
        if textView.selectedRanges != selection { textView.selectedRanges = selection }
        updateReveal(force: true)
        resetTypingAttributes()
    }

    /// Range (in the new text) of blocks that differ from the old parse, found by trimming the
    /// common prefix and suffix. A fence opened or closed makes everything after it differ.
    private func changedBlocks(old: MarkdownDocument, new: MarkdownDocument, delta: Int) -> NSRange? {
        let a = old.blocks, b = new.blocks
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              shifted(a[a.count - 1 - suffix], by: delta) == b[b.count - 1 - suffix] { suffix += 1 }
        let lo = prefix, hi = b.count - 1 - suffix
        guard lo <= hi else { return nil }
        return NSUnionRange(b[lo].range, b[hi].range)
    }

    private func shifted(_ block: Block, by delta: Int) -> Block {
        func s(_ r: NSRange) -> NSRange { NSRange(location: r.location + delta, length: r.length) }
        return Block(kind: block.kind, range: s(block.range), markerRanges: block.markerRanges.map(s), contentRange: s(block.contentRange))
    }

    /// Updates which markers are shown for the current selection, re-laying-out only the blocks
    /// whose visibility can change (old and new caret blocks).
    func updateReveal(force: Bool = false) {
        guard textStorage.length == document.length, !textView.hasMarkedText() else { return }
        let selection = textView.selectedRange()
        var blocks: [NSRange] = []
        if let idx = document.blockIndexes(intersecting: selection) {
            blocks = idx.map { document.blocks[$0].range }
        }
        let oldBlocks = hiding.revealedBlocks
        guard force || selection != hiding.selection || blocks != oldBlocks else { return }
        hiding.selection = selection
        hiding.revealedBlocks = blocks
        let length = textStorage.length
        for r in Set((oldBlocks + blocks).map { NSRangeKey($0) }) {
            let range = NSIntersectionRange(r.range, NSRange(location: 0, length: length))
            guard range.length > 0 else { continue }
            layoutManager.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
            layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        }
        textView.needsDisplay = true
    }

    /// New text takes the block's base look, never a marker's or a link's attributes.
    private func resetTypingAttributes() {
        let loc = textView.selectedRange().location
        let kind = document.blockIndex(containing: loc).map { document.blocks[$0].kind }
        var attrs = styler.typingAttributes(for: kind)
        // Inside a styled inline run (e.g. bold), keep that run's font.
        if loc > 0, loc <= textStorage.length, textStorage.attribute(.mdMarker, at: loc - 1, effectiveRange: nil) == nil,
           let font = textStorage.attribute(.font, at: loc - 1, effectiveRange: nil) {
            attrs[.font] = font
        }
        textView.typingAttributes = attrs
    }
}

private struct NSRangeKey: Hashable {
    let range: NSRange
    init(_ r: NSRange) { range = r }
    func hash(into h: inout Hasher) { h.combine(range.location); h.combine(range.length) }
    static func == (a: NSRangeKey, b: NSRangeKey) -> Bool { NSEqualRanges(a.range, b.range) }
}
