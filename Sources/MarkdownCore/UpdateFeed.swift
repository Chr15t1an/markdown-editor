import Foundation

/// The site's update feed, `https://markdown.chri5tian.com/version.json`, rendered per release by
/// `scripts/package-release.sh` from `site/version.template.json`: `{"version": "0.3.2", "url": "…"}`.
public struct UpdateFeed: Decodable, Equatable, Sendable {
    public let version: String
    public let url: URL

    public init(version: String, url: URL) {
        self.version = version
        self.url = url
    }
}

/// Pure rules behind the app's update check (the network and the alerts live in the app target).
public enum UpdateCheck {
    /// The only host a feed's download link may point at; anything else opens `siteURL` instead.
    public static let siteHost = "markdown.chri5tian.com"
    public static let siteURL = URL(string: "https://markdown.chri5tian.com/")!
    public static let defaultInterval: TimeInterval = 86_400

    public static func parse(_ data: Data) throws -> UpdateFeed {
        try JSONDecoder().decode(UpdateFeed.self, from: data)
    }

    /// Numeric `x.y.z` comparison: missing parts count as 0 (`1.0` == `1.0.0`), and anything that
    /// is not dot-separated decimal numbers (empty, letters, a leading `v`, overflow) is never newer.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let new = numericParts(candidate), let old = numericParts(current) else { return false }
        let count = max(new.count, old.count)
        for i in 0..<count {
            let a = i < new.count ? new[i] : 0
            let b = i < old.count ? old[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// True when no check has succeeded yet, the last one is `interval` or more ago, or the stored
    /// date is in the future (the clock moved back), so a bad date never stops checks for good.
    public static func isDue(last: Date?, now: Date, interval: TimeInterval = defaultInterval) -> Bool {
        guard let last else { return true }
        let elapsed = now.timeIntervalSince(last)
        return elapsed >= interval || elapsed < 0
    }

    /// Where **Download** goes: the feed's link only if it is https on the site's own host, else the
    /// site root, so a tampered feed cannot send the user anywhere else.
    public static func downloadURL(for feed: UpdateFeed) -> URL {
        isSiteURL(feed.url) ? feed.url : siteURL
    }

    /// A feed URL the app will fetch: https on any host (the shipping value is the site), or
    /// `http://127.0.0.1:<port>` for a local test server — the same rule `install.sh` applies to
    /// `MARKDOWN_EDITOR_BASE_URL`.
    public static func isAllowedFeedURL(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return url.host?.isEmpty == false
        case "http": return url.host == "127.0.0.1" && url.port != nil
        default: return false
        }
    }

    static func isSiteURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == siteHost && url.port == nil && url.user == nil
    }

    private static func numericParts(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(part) else { return nil }
            numbers.append(n)
        }
        return numbers
    }
}
