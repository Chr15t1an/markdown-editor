import CryptoKit
import Foundation

/// The site's update feed, `https://markdown.chri5tian.com/version.json`, rendered per release by
/// `scripts/package-release.sh` from `site/version.template.json`:
/// `{"version": "0.7.0", "url": "…", "zip": "Markdown-Editor-0.7.0.zip", "sha256": "…", "signature": "…"}`.
/// `zip`, `sha256` and `signature` (0.7.0 and later) let the app install the update itself; older
/// apps ignore them and only read `version` and `url`.
public struct UpdateFeed: Decodable, Equatable, Sendable {
    public let version: String
    public let url: URL
    public let zip: String?
    public let sha256: String?
    public let signature: String?

    public init(version: String, url: URL, zip: String? = nil, sha256: String? = nil, signature: String? = nil) {
        self.version = version
        self.url = url
        self.zip = zip
        self.sha256 = sha256
        self.signature = signature
    }
}

/// A release the app may download and install: the zip's address, the SHA-256 its bytes must have,
/// and the version the app inside must report. Only made by `UpdateCheck.package(for:feedURL:publicKey:)`,
/// after the feed's Ed25519 signature over (version, sha256) checks out.
public struct UpdatePackage: Equatable, Sendable {
    public let version: String
    public let zipURL: URL
    public let sha256: String
}

/// The release signature: Ed25519 over `markdown-editor-update:v1:<version>:<sha256>`. The private key
/// lives only with whoever cuts releases (`scripts/update-key.sh`); the public key ships in the app's
/// Info.plist (`MEUpdatePublicKey`). The signature binds the version to the exact zip bytes, so a
/// tampered feed or zip — even one served from the real site — is refused, and an old signed
/// release can't be replayed as an "update" because the version must also be newer.
public enum UpdateSignature {
    public static func message(version: String, sha256: String) -> Data {
        Data("markdown-editor-update:v1:\(version):\(sha256.lowercased())".utf8)
    }

    public static func isValid(signature: String, version: String, sha256: String, publicKey: String) -> Bool {
        guard let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let sig = Data(base64Encoded: signature) else { return false }
        return key.isValidSignature(sig, for: message(version: version, sha256: sha256))
    }

    /// Base64 signature (used by the release tooling; the app only verifies).
    public static func sign(version: String, sha256: String, privateKey: String) throws -> String {
        guard let keyData = Data(base64Encoded: privateKey) else { throw CryptoKitError.incorrectKeySize }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
        return try key.signature(for: message(version: version, sha256: sha256)).base64EncodedString()
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

    /// The installable release behind a feed, or nil (then the app falls back to **Download**). All of:
    /// the version is plain `x.y.z`; `zip` is exactly `Markdown-Editor-<version>.zip`; `sha256` is 64
    /// hex digits; the signature verifies with `publicKey`. The zip is fetched from the feed's own
    /// folder, so it inherits the feed URL's https-or-local-test rule.
    public static func package(for feed: UpdateFeed, feedURL: URL, publicKey: String?) -> UpdatePackage? {
        guard let publicKey, let zip = feed.zip, let sha = feed.sha256?.lowercased(), let signature = feed.signature,
              isAllowedFeedURL(feedURL), numericParts(feed.version) != nil,
              zip == "Markdown-Editor-\(feed.version).zip",
              sha.count == 64, sha.allSatisfy({ $0.isHexDigit && $0.isASCII }),
              UpdateSignature.isValid(signature: signature, version: feed.version, sha256: sha, publicKey: publicKey)
        else { return nil }
        let zipURL = feedURL.deletingLastPathComponent().appendingPathComponent(zip)
        return UpdatePackage(version: feed.version, zipURL: zipURL, sha256: sha)
    }

    /// Lowercase hex SHA-256 of a file, read in 1 MB chunks.
    public static func sha256(ofFile url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
