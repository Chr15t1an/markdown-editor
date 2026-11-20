import AppKit
import MarkdownCore

/// Installs a verified release in place of the running app, then relaunches it.
///
/// Before anything touches the installed app, every one of these must hold (any failure leaves the
/// installed copy as it was and the user gets the **Download** fallback):
/// 1. the feed's Ed25519 signature over (version, SHA-256) verifies with the key in Info.plist
///    (`UpdateCheck.package`, done by the caller);
/// 2. the downloaded zip's SHA-256 is the signed one;
/// 3. the zip holds exactly `Markdown Editor.app`, whose code signature verifies (`codesign --strict`),
///    whose bundle id is this app's, and whose version is the signed version;
/// 4. the running app sits somewhere this user can write (not App Translocation, not a read-only volume).
/// Then the new copy is staged beside the old one, swapped in by two renames (the old one is put back
/// if the second fails), and a detached `/bin/sh` waits for this process to exit and opens the new copy.
/// URLSession downloads are not quarantined, so the new copy opens without a Gatekeeper prompt — the
/// same as `install.sh`.
@MainActor
final class UpdateInstaller {
    enum InstallError: LocalizedError {
        case translocated
        case notWritable(String)
        case download(String)
        case checksum
        case badArchive(String)
        case swap(String)

        var errorDescription: String? {
            switch self {
            case .translocated:
                return "Markdown Editor is running from a temporary location macOS uses for apps that haven’t been moved. Move it to Applications, open it from there, and try again."
            case .notWritable(let folder):
                return "Markdown Editor can’t replace itself in \(folder)."
            case .download(let reason): return "The download failed: \(reason)"
            case .checksum: return "The downloaded file doesn’t match the signed release, so it wasn’t installed."
            case .badArchive(let reason): return "The downloaded app failed a check (\(reason)), so it wasn’t installed."
            case .swap(let reason): return "The new version couldn’t be put in place: \(reason). The current version was left as it was."
            }
        }
    }

    typealias Download = @Sendable (URL, URL) async throws -> Void   // (from, to file)

    let appURL: URL
    let bundleID: String
    private let download: Download
    private let fileManager = FileManager.default
    nonisolated static let maxBytes = 200_000_000

    init(appURL: URL = Bundle.main.bundleURL,
         bundleID: String = Bundle.main.bundleIdentifier ?? "com.chri5tian.markdown-editor",
         download: @escaping Download = UpdateInstaller.liveDownload) {
        self.appURL = appURL.standardizedFileURL
        self.bundleID = bundleID
        self.download = download
    }

    /// Why this copy can't update itself, or nil if it can.
    func locationProblem() -> InstallError? {
        if appURL.path.contains("/AppTranslocation/") { return .translocated }
        let folder = appURL.deletingLastPathComponent().path
        guard fileManager.isWritableFile(atPath: folder), fileManager.isWritableFile(atPath: appURL.path) else {
            return .notWritable(folder)
        }
        return nil
    }

    /// Downloads and checks the release, and stages it beside the running app. Returns the staged copy.
    func prepare(_ package: UpdatePackage) async throws -> URL {
        if let problem = locationProblem() { throw problem }
        let work = fileManager.temporaryDirectory.appendingPathComponent("markdown-editor-update-\(UUID().uuidString)")
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }

        let zip = work.appendingPathComponent(package.zipURL.lastPathComponent)
        do { try await download(package.zipURL, zip) } catch { throw InstallError.download(error.localizedDescription) }
        guard try UpdateCheck.sha256(ofFile: zip) == package.sha256 else { throw InstallError.checksum }

        let unzipped = work.appendingPathComponent("unzipped")
        guard Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unzipped.path]) else { throw InstallError.badArchive("unzip failed") }
        let contents = (try? fileManager.contentsOfDirectory(atPath: unzipped.path)) ?? []
        guard contents == [appURL.lastPathComponent] || contents == ["Markdown Editor.app"] else {
            throw InstallError.badArchive("unexpected contents")
        }
        let newApp = unzipped.appendingPathComponent(contents[0])
        try verifyApp(newApp, version: package.version)

        let staged = appURL.deletingLastPathComponent()
            .appendingPathComponent(".\(appURL.lastPathComponent).new.\(ProcessInfo.processInfo.processIdentifier)")
        try? fileManager.removeItem(at: staged)
        guard Self.run("/usr/bin/ditto", [newApp.path, staged.path]) else {
            try? fileManager.removeItem(at: staged)
            throw InstallError.notWritable(appURL.deletingLastPathComponent().path)
        }
        do { try verifyApp(staged, version: package.version) } catch {
            try? fileManager.removeItem(at: staged)
            throw error
        }
        return staged
    }

    func discard(_ staged: URL) { try? fileManager.removeItem(at: staged) }

    /// Swaps the staged copy in (old aside, new in, old back on failure) and starts the relaunch
    /// helper. The caller then quits the app; the helper opens the new copy once this process is gone
    /// and deletes the old one.
    func installAndScheduleRelaunch(_ staged: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let old = appURL.deletingLastPathComponent().appendingPathComponent(".\(appURL.lastPathComponent).old.\(pid)")
        try? fileManager.removeItem(at: old)
        do { try fileManager.moveItem(at: appURL, to: old) } catch {
            discard(staged)
            throw InstallError.swap(error.localizedDescription)
        }
        do { try fileManager.moveItem(at: staged, to: appURL) } catch {
            try? fileManager.moveItem(at: old, to: appURL)
            discard(staged)
            throw InstallError.swap(error.localizedDescription)
        }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Waits up to ~2 min for this process to exit, then opens the new copy and deletes the old.
        helper.arguments = ["-c", """
            i=0; while /bin/kill -0 "$1" 2>/dev/null && [ $i -lt 600 ]; do /bin/sleep 0.2; i=$((i+1)); done
            /bin/rm -rf "$3"
            /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$2" >/dev/null 2>&1
            /usr/bin/open "$2"
            """, "sh", String(pid), appURL.path, old.path]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try? helper.run()
    }

    private func verifyApp(_ app: URL, version: String) throws {
        guard Self.run("/usr/bin/codesign", ["--verify", "--strict", app.path]) else {
            throw InstallError.badArchive("code signature")
        }
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
            throw InstallError.badArchive("no Info.plist")
        }
        guard info["CFBundleIdentifier"] as? String == bundleID else { throw InstallError.badArchive("bundle id") }
        guard info["CFBundleShortVersionString"] as? String == version else { throw InstallError.badArchive("version") }
    }

    @discardableResult
    nonisolated static func run(_ tool: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Ephemeral GET (no cookies, no cache, constant User-Agent), 200 only, size-capped, moved to `to`.
    nonisolated static let liveDownload: Download = { from, to in
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: from, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue(UpdateChecker.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        let (file, response) = try await session.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateChecker.FetchError.status(status) }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        guard size <= maxBytes else { throw UpdateChecker.FetchError.status(413) }
        try FileManager.default.moveItem(at: file, to: to)
    }
}
