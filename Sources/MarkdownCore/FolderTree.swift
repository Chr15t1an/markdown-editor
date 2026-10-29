import Foundation

public enum FolderTree {
    /// File extensions the sidebar lists (compared case-insensitively).
    public static let markdownExtensions: Set<String> = ["md", "markdown"]

    public static func isMarkdown(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    /// Markdown or image: the files the sidebar lists and an open can select.
    public static func isListed(_ url: URL) -> Bool { isMarkdown(url) || ImageFile.isImage(url) }
}

/// One entry in the sidebar tree. Directory children are read lazily, on first request.
public final class FileNode {
    public let url: URL
    public let isDirectory: Bool
    public weak private(set) var parent: FileNode?
    public private(set) var children: [FileNode]?

    public var name: String { url.lastPathComponent }
    public var isLoaded: Bool { children != nil }
    public var isImage: Bool { !isDirectory && ImageFile.isImage(url) }

    public init(url: URL, isDirectory: Bool, parent: FileNode? = nil) {
        self.url = url.standardizedFileURL
        self.isDirectory = isDirectory
        self.parent = parent
    }

    /// Returns the children, reading the directory the first time.
    @discardableResult
    public func loadChildren() -> [FileNode] {
        if let children { return children }
        let listed = list(reusing: [:])
        children = listed
        return listed
    }

    /// Re-reads the directory, keeping existing child objects (and so their loaded subtrees and
    /// outline-view expansion state) for entries that are still there.
    public func reload() {
        guard isDirectory else { return }
        var existing: [URL: FileNode] = [:]
        for child in children ?? [] { existing[child.url] = child }
        children = list(reusing: existing)
    }

    /// The loaded descendant (or self) whose URL is `target`, without reading the disk.
    public func loadedNode(for target: URL) -> FileNode? {
        let target = target.standardizedFileURL
        if url == target { return self }
        let mine = url.pathComponents, theirs = target.pathComponents
        guard theirs.count > mine.count, Array(theirs.prefix(mine.count)) == mine else { return nil }
        for child in children ?? [] {
            if let hit = child.loadedNode(for: target) { return hit }
        }
        return nil
    }

    /// The descendant whose URL is `target`, reading directories on the way as needed.
    public func node(for target: URL) -> FileNode? {
        let target = target.standardizedFileURL
        if url == target { return self }
        let mine = url.pathComponents, theirs = target.pathComponents
        guard isDirectory, theirs.count > mine.count, Array(theirs.prefix(mine.count)) == mine else { return nil }
        let next = theirs[mine.count]
        return loadChildren().first { $0.name == next }?.node(for: target)
    }

    private func list(reusing existing: [URL: FileNode]) -> [FileNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .isPackageKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var nodes: [FileNode] = []
        for childURL in urls {
            let values = try? childURL.resourceValues(forKeys: Set(keys))
            if values?.isHidden == true { continue }
            let isDir = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
            guard isDir || FolderTree.isListed(childURL) else { continue }
            let standardized = childURL.standardizedFileURL
            if let old = existing[standardized], old.isDirectory == isDir {
                nodes.append(old)
            } else {
                nodes.append(FileNode(url: standardized, isDirectory: isDir, parent: self))
            }
        }
        nodes.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return nodes
    }
}

/// What an opened URL means for the window: a folder to show, and optionally a file in it.
public enum OpenTarget {
    /// A folder, or a markdown or image file: the folder to show and the file to select in it.
    /// Nil for anything else, or a path that does not exist.
    public static func resolve(_ url: URL) -> (folder: URL, file: URL?)? {
        let url = url.standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        if isDir.boolValue { return (url, nil) }
        guard FolderTree.isListed(url) else { return nil }
        return (url.deletingLastPathComponent().standardizedFileURL, url)
    }

    /// The file a relaunch reopens: `path` when it names a listed kind (markdown or image) that
    /// exists inside `folder`. Nil otherwise.
    public static func restorableFile(_ path: String?, in folder: URL) -> URL? {
        guard let path else { return nil }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        let root = folder.standardizedFileURL.path
        guard file.path.hasPrefix(root.hasSuffix("/") ? root : root + "/"), FolderTree.isListed(file),
              FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }
}
