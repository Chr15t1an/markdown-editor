import AppKit
import MarkdownCore

/// The app's only network request: an optional check of the site's `version.json` for a newer
/// release. It is a notice plus a link to the site, not an updater (ad-hoc builds can't use Sparkle).
///
/// - Manual: app menu › Check for Updates… always fetches and always says what it found.
/// - Automatic: off until the user answers a one-time sheet on the second launch (or ticks
///   app menu › Check for Updates Automatically). When on, at most once per 24 h at launch, silent
///   unless a newer version exists, and each new version is shown once.
/// - The request is a plain GET with a constant User-Agent, no query string, no cookies, no cache.
@MainActor
final class UpdateChecker {
    static let autoKey = "checkForUpdatesAutomatically"   // absent = not asked yet
    static let lastCheckKey = "lastUpdateCheck"
    static let lastNotifiedKey = "lastNotifiedUpdateVersion"
    static let launchCountKey = "launchCount"
    /// Info.plist key with the shipping feed URL; also accepted as a launch argument
    /// (`open … --args -MEUpdateFeedURL http://127.0.0.1:<port>/version.json`) for local tests.
    static let feedURLKey = "MEUpdateFeedURL"
    /// Launch argument or default that keeps the launch path from asking or checking (for probes).
    static let disabledKey = "MEUpdateCheckDisabled"
    nonisolated static let userAgent = "Markdown Editor"

    typealias Fetch = @Sendable (URL) async throws -> Data

    enum Presentation: Equatable {
        case available(UpdateFeed, current: String)
        case upToDate(current: String)
        case failed(message: String)
        case askToEnable
    }

    enum Outcome: Equatable {
        case available(UpdateFeed)
        case upToDate
        case failed(String)
        case skipped
        case asked
    }

    enum FetchError: LocalizedError {
        case noFeedURL
        case status(Int)

        var errorDescription: String? {
            switch self {
            case .noFeedURL: return "This copy of Markdown Editor has no update address."
            case .status(let code): return "The site answered with HTTP status \(code)."
            }
        }
    }

    let feedURL: URL?
    let currentVersion: String
    let defaults: UserDefaults
    private let fetch: Fetch
    var now: () -> Date = Date.init
    /// Shows a presentation; returns false when it couldn't (no window, another sheet is up).
    var present: (Presentation) -> Bool = { _ in false }

    init(feedURL: URL?, currentVersion: String, defaults: UserDefaults = .standard,
         fetch: @escaping Fetch = UpdateChecker.liveFetch) {
        self.feedURL = feedURL
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.fetch = fetch
    }

    var automaticChecksEnabled: Bool {
        get { defaults.object(forKey: Self.autoKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Self.autoKey) }
    }

    var hasAnsweredAutomaticQuestion: Bool { defaults.object(forKey: Self.autoKey) != nil }

    // MARK: Launch

    /// Counts the launch, then on the second launch (if never answered) asks whether to check
    /// automatically, else runs the automatic check if it is on and due.
    @discardableResult
    func handleLaunch() async -> Outcome {
        let launches = defaults.integer(forKey: Self.launchCountKey) + 1
        defaults.set(launches, forKey: Self.launchCountKey)
        if !hasAnsweredAutomaticQuestion {
            guard launches >= 2 else { return .skipped }
            return present(.askToEnable) ? .asked : .skipped
        }
        return await checkIfDue()
    }

    /// The one-time sheet's answer (also what the menu toggle sets).
    @discardableResult
    func answerAutomaticQuestion(_ enabled: Bool) async -> Outcome {
        automaticChecksEnabled = enabled
        return enabled ? await checkIfDue() : .skipped
    }

    // MARK: Checks

    /// Automatic: only when on and 24 h have passed; silent on failure or when up to date; a given
    /// newer version is shown once.
    @discardableResult
    func checkIfDue() async -> Outcome {
        guard automaticChecksEnabled,
              UpdateCheck.isDue(last: defaults.object(forKey: Self.lastCheckKey) as? Date, now: now()) else { return .skipped }
        let feed: UpdateFeed
        do {
            feed = try await load()
        } catch {
            return .failed(error.localizedDescription)
        }
        guard UpdateCheck.isNewer(feed.version, than: currentVersion) else { return .upToDate }
        guard defaults.string(forKey: Self.lastNotifiedKey) != feed.version else { return .skipped }
        if present(.available(feed, current: currentVersion)) {
            defaults.set(feed.version, forKey: Self.lastNotifiedKey)
        }
        return .available(feed)
    }

    /// Manual (Check for Updates…): always fetches and always reports.
    @discardableResult
    func checkNow() async -> Outcome {
        do {
            let feed = try await load()
            if UpdateCheck.isNewer(feed.version, than: currentVersion) {
                if present(.available(feed, current: currentVersion)) {
                    defaults.set(feed.version, forKey: Self.lastNotifiedKey)
                }
                return .available(feed)
            }
            _ = present(.upToDate(current: currentVersion))
            return .upToDate
        } catch {
            _ = present(.failed(message: error.localizedDescription))
            return .failed(error.localizedDescription)
        }
    }

    private func load() async throws -> UpdateFeed {
        guard let feedURL else { throw FetchError.noFeedURL }
        let feed = try UpdateCheck.parse(try await fetch(feedURL))
        defaults.set(now(), forKey: Self.lastCheckKey)
        return feed
    }

    // MARK: Live wiring

    /// GET with a 15 s timeout, no cache, no cookies, and a constant User-Agent / Accept-Language so
    /// the request carries no build, OS or locale details. Anything but HTTP 200 is an error.
    nonisolated static let liveFetch: Fetch = { url in
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw FetchError.status(status) }
        return data
    }

    /// The feed URL: a `-MEUpdateFeedURL` launch argument (never read from the persistent defaults
    /// domain) if allowed, else Info.plist's `MEUpdateFeedURL`. Both must pass `isAllowedFeedURL`.
    static func resolveFeedURL(bundle: Bundle = .main,
                               arguments: [String: Any] = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)) -> URL? {
        let candidates = [arguments[feedURLKey] as? String, bundle.object(forInfoDictionaryKey: feedURLKey) as? String]
        for case let string? in candidates {
            if let url = URL(string: string), UpdateCheck.isAllowedFeedURL(url) { return url }
        }
        return nil
    }

    static func bundleVersion(_ bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? MarkdownCore.version
    }
}

/// The checker's sheets, per DESIGN.md: NSAlert sheets on the main window, titles say what
/// happened, buttons are verbs.
@MainActor
struct UpdateAlerts {
    let window: () -> NSWindow?
    let openURL: (URL) -> Void
    let answer: (Bool) -> Void

    func present(_ presentation: UpdateChecker.Presentation) -> Bool {
        let alert = NSAlert()
        var onFirstButton: (() -> Void)?
        var onSecondButton: (() -> Void)?
        switch presentation {
        case let .available(feed, current):
            alert.messageText = "Markdown Editor \(feed.version) is available"
            alert.informativeText = "You have \(current). Download the new version from markdown.chri5tian.com."
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Skip This Version")   // the automatic check shows a version once
            let url = UpdateCheck.downloadURL(for: feed)
            onFirstButton = { openURL(url) }
        case let .upToDate(current):
            alert.messageText = "You’re up to date"
            alert.informativeText = "Markdown Editor \(current) is the newest version."
            alert.addButton(withTitle: "OK")
        case let .failed(message):
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t check for updates"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
        case .askToEnable:
            alert.messageText = "Check for updates automatically?"
            alert.informativeText = "Markdown Editor can ask markdown.chri5tian.com once a day whether a newer version exists. Like any web request, the site sees your IP address; nothing else is sent. You can change this in the Markdown Editor menu."
            alert.addButton(withTitle: "Check Automatically")
            alert.addButton(withTitle: "Don’t Check")
            onFirstButton = { answer(true) }
            onSecondButton = { answer(false) }
        }
        guard let window = window(), window.attachedSheet == nil else { return false }
        ProbeLog.shared.alertShown(alert.messageText)
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                ProbeLog.shared.alertShown("")
                switch response {
                case .alertFirstButtonReturn: onFirstButton?()
                case .alertSecondButtonReturn: onSecondButton?()
                default: break
                }
            }
        }
        return true
    }
}
