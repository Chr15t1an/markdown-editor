import AppKit
import MarkdownCore
import UniformTypeIdentifiers

/// The folder tree: an NSOutlineView over lazily-read `FileNode`s.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outlineView = NSOutlineView()
    private(set) var root: FileNode?
    var onSelectFile: ((URL) -> Void)?
    private var watcher: FolderWatcher?
    private var isRevealing = false

    override func loadView() {
        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.setAccessibilityIdentifier("sidebar")

        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        view = scroll
    }

    // MARK: Root

    func setRoot(_ folder: URL) {
        watcher?.stop()
        let node = FileNode(url: folder, isDirectory: true)
        root = node
        node.loadChildren()
        outlineView.autosaveExpandedItems = false
        outlineView.reloadData()
        outlineView.autosaveName = "Sidebar:" + folder.path
        outlineView.autosaveExpandedItems = true
        watcher = FolderWatcher(folder: folder) { [weak self] paths in self?.filesChanged(paths) }
    }

    /// Expands the parents of `file` and selects its row.
    func reveal(_ file: URL) {
        guard let root, let node = root.node(for: file) else { return }
        var chain: [FileNode] = []
        var parent = node.parent
        while let p = parent, p !== root { chain.insert(p, at: 0); parent = p.parent }
        for p in chain { outlineView.expandItem(p) }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        isRevealing = true
        outlineView.selectRowIndexes([row], byExtendingSelection: false)
        isRevealing = false
        outlineView.scrollRowToVisible(row)
    }

    /// Selects `file`'s row (or clears the selection) without reporting it as a user choice.
    func selectFile(_ file: URL?) {
        guard let file else {
            isRevealing = true
            outlineView.deselectAll(nil)
            isRevealing = false
            return
        }
        reveal(file)
    }

    var selectedFile: URL? {
        (outlineView.item(atRow: outlineView.selectedRow) as? FileNode).flatMap { $0.isDirectory ? nil : $0.url }
    }

    /// The folder the selection is "in": a selected folder row, or a selected file's folder.
    /// Nil when nothing is selected.
    var selectedDirectory: URL? {
        guard let node = outlineView.item(atRow: outlineView.selectedRow) as? FileNode else { return nil }
        if node.isDirectory { return node.url }
        return node.parent?.url ?? node.url.deletingLastPathComponent().standardizedFileURL
    }

    /// Re-reads `directory` if its children are already loaded, so a file just created in it can
    /// be revealed at once (a loaded folder otherwise only learns of it when FSEvents fires).
    func refresh(directory: URL) {
        guard let root, let node = root.loadedNode(for: directory), node.isDirectory, node.isLoaded else { return }
        isRevealing = true
        node.reload()
        outlineView.reloadItem(node === root ? nil : node, reloadChildren: true)
        isRevealing = false
    }

    /// Names of the rows currently shown, indented two spaces per level (probe/debug output).
    var visibleRowNames: [String] {
        (0..<outlineView.numberOfRows).compactMap { row in
            guard let node = outlineView.item(atRow: row) as? FileNode else { return nil }
            return String(repeating: "  ", count: outlineView.level(forRow: row)) + node.name
        }
    }

    private func filesChanged(_ paths: [String]) {
        guard let root else { return }
        let rootPath = root.url.resolvingSymlinksInPath().path
        var dirty: [FileNode] = []
        for path in paths {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard url.path.hasPrefix(rootPath) else { continue }
            let relative = String(url.path.dropFirst(rootPath.count))
            let mapped = URL(fileURLWithPath: root.url.path + relative)
            for candidate in [mapped, mapped.deletingLastPathComponent()] {
                if let node = root.loadedNode(for: candidate), node.isDirectory, node.isLoaded,
                   !dirty.contains(where: { $0 === node }) {
                    dirty.append(node)
                }
            }
        }
        guard !dirty.isEmpty else { return }
        let selected = selectedFile
        for node in dirty {
            node.reload()
            outlineView.reloadItem(node === root ? nil : node, reloadChildren: true)
        }
        if let selected { reveal(selected) }
        ProbeLog.shared.dump()
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = (item as? FileNode) ?? root else { return 0 }
        return node.isDirectory ? node.loadChildren().count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let node = (item as? FileNode) ?? root!
        return node.loadChildren()[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, persistentObjectForItem item: Any?) -> Any? {
        (item as? FileNode)?.url.path
    }

    func outlineView(_ outlineView: NSOutlineView, itemForPersistentObject object: Any) -> Any? {
        guard let path = object as? String else { return nil }
        return root?.node(for: URL(fileURLWithPath: path))
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCell(id)
        cell.textField?.stringValue = node.name
        cell.imageView?.image = node.isDirectory
            ? NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")
            : NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Markdown file")
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let image = NSImageView()
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        for v in [image, text] { v.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(v) }
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isRevealing, let file = selectedFile else { return }
        onSelectFile?(file)
    }
}
