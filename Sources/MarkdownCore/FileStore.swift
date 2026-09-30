import Foundation

/// A note's text as read from disk, with what is needed to write it back faithfully.
public struct FileContents: Equatable, Sendable {
    public var text: String
    public var encoding: String.Encoding
    public var modificationDate: Date?
}

/// Reads and writes note files as plain text.
public enum FileStore {
    /// Reads `url` (UTF-8, else the encoding Foundation detects). Not coordinated.
    public static func read(_ url: URL) throws -> String { try readContents(url).text }

    public static func readContents(_ url: URL) throws -> FileContents {
        let data = try Data(contentsOf: url)
        let date = modificationDate(url)
        if let text = String(data: data, encoding: .utf8) { return FileContents(text: text, encoding: .utf8, modificationDate: date) }
        var encoding = String.Encoding.utf8
        let text = try String(contentsOf: url, usedEncoding: &encoding)
        return FileContents(text: text, encoding: encoding, modificationDate: date)
    }

    /// Reads under file coordination, so a coordinated writer is never seen half-done.
    public static func readCoordinated(_ url: URL, presenter: NSFilePresenter? = nil) throws -> FileContents {
        var coordinationError: NSError?
        var result: Result<FileContents, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator(filePresenter: presenter).coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            result = Result { try readContents(target) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    public static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.modificationDate] as? Date
    }

    /// Writes `text` to `url` through file coordination, in `encoding`. A symlink is followed
    /// and its target replaced. Replaces the file via `FileManager.replaceItemAt`, which keeps its
    /// permissions, creation date and extended attributes (`Data.write(options: .atomic)` would
    /// reset them). Returns `false` without touching the file when it already holds exactly
    /// these bytes. With `createIfMissing: false`, a file that no longer exists is not recreated
    /// (throws `CocoaError.fileNoSuchFile`).
    @discardableResult
    public static func write(_ text: String, to url: URL, encoding: String.Encoding = .utf8,
                             createIfMissing: Bool = true, presenter: NSFilePresenter? = nil) throws -> Bool {
        guard let data = text.data(using: encoding, allowLossyConversion: false) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding, userInfo: [NSFilePathErrorKey: url.path])
        }
        let target = url.resolvingSymlinksInPath()
        var coordinationError: NSError?
        var writeError: Error?
        var wrote = false
        NSFileCoordinator(filePresenter: presenter).coordinate(
            writingItemAt: target, options: .forReplacing, error: &coordinationError
        ) { coordinated in
            do {
                wrote = try replace(coordinated, with: data, createIfMissing: createIfMissing)
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
        return wrote
    }

    private static func replace(_ url: URL, with data: Data, createIfMissing: Bool) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            guard createIfMissing else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path]) }
            try data.write(to: url)
            return true
        }
        if let current = try? Data(contentsOf: url), current == data { return false }
        let scratch = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: url, create: true)
        defer { try? fm.removeItem(at: scratch) }
        let temp = scratch.appendingPathComponent(url.lastPathComponent)
        try data.write(to: temp)
        _ = try fm.replaceItemAt(url, withItemAt: temp)
        return true
    }
}
