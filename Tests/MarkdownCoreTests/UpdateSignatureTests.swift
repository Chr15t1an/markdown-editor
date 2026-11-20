import CryptoKit
import XCTest
@testable import MarkdownCore

final class UpdateSignatureTests: XCTestCase {
    let privateKey = Curve25519.Signing.PrivateKey()
    var publicB64: String { privateKey.publicKey.rawRepresentation.base64EncodedString() }
    var privateB64: String { privateKey.rawRepresentation.base64EncodedString() }
    let sha = String(repeating: "ab", count: 32)
    let feedURL = URL(string: "https://markdown.chri5tian.com/version.json")!

    func signedFeed(version: String = "0.7.0", sha: String? = nil, signVersion: String? = nil, zip: String? = nil) throws -> UpdateFeed {
        let sha = sha ?? self.sha
        let sig = try UpdateSignature.sign(version: signVersion ?? version, sha256: sha, privateKey: privateB64)
        return UpdateFeed(version: version, url: URL(string: "https://markdown.chri5tian.com/")!,
                          zip: zip ?? "Markdown-Editor-\(version).zip", sha256: sha, signature: sig)
    }

    func testSignedFeedGivesPackageNextToTheFeed() throws {
        let package = UpdateCheck.package(for: try signedFeed(), feedURL: feedURL, publicKey: publicB64)
        XCTAssertEqual(package?.zipURL, URL(string: "https://markdown.chri5tian.com/Markdown-Editor-0.7.0.zip"))
        XCTAssertEqual(package?.sha256, sha)
        XCTAssertEqual(package?.version, "0.7.0")
    }

    func testParsesNewFieldsAndOldFeedsStillParse() throws {
        let json = #"{"version":"0.7.0","url":"https://markdown.chri5tian.com/","zip":"Markdown-Editor-0.7.0.zip","sha256":"\#(sha)","signature":"x"}"#
        let feed = try UpdateCheck.parse(Data(json.utf8))
        XCTAssertEqual(feed.zip, "Markdown-Editor-0.7.0.zip")
        XCTAssertEqual(feed.signature, "x")
        let old = try UpdateCheck.parse(Data(#"{"version":"0.6.0","url":"https://markdown.chri5tian.com/"}"#.utf8))
        XCTAssertNil(UpdateCheck.package(for: old, feedURL: feedURL, publicKey: publicB64), "unsigned feed = Download only")
    }

    func testRefusesTamperedOrMismatchedFeeds() throws {
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertNil(UpdateCheck.package(for: try signedFeed(), feedURL: feedURL, publicKey: other), "wrong key")
        XCTAssertNil(UpdateCheck.package(for: try signedFeed(), feedURL: feedURL, publicKey: nil), "no key in the app")
        // version swapped after signing (replaying an old signed release as a newer version)
        XCTAssertNil(UpdateCheck.package(for: try signedFeed(version: "9.9.9", signVersion: "0.7.0"), feedURL: feedURL, publicKey: publicB64))
        // sha swapped after signing
        var f = try signedFeed()
        f = UpdateFeed(version: f.version, url: f.url, zip: f.zip, sha256: String(repeating: "cd", count: 32), signature: f.signature)
        XCTAssertNil(UpdateCheck.package(for: f, feedURL: feedURL, publicKey: publicB64))
        // zip name must be exactly Markdown-Editor-<version>.zip (no paths, no other hosts)
        for zip in ["../evil.zip", "https://evil.example/Markdown-Editor-0.7.0.zip", "Markdown-Editor-0.6.0.zip", "a/Markdown-Editor-0.7.0.zip"] {
            XCTAssertNil(UpdateCheck.package(for: try signedFeed(zip: zip), feedURL: feedURL, publicKey: publicB64), zip)
        }
        XCTAssertNil(UpdateCheck.package(for: try signedFeed(sha: "abc"), feedURL: feedURL, publicKey: publicB64), "short sha")
        XCTAssertNil(UpdateCheck.package(for: try signedFeed(version: "0.7.0-beta"), feedURL: feedURL, publicKey: publicB64))
        XCTAssertNil(UpdateCheck.package(for: try signedFeed(), feedURL: URL(string: "http://evil.example/version.json")!, publicKey: publicB64))
        XCTAssertNil(UpdateCheck.package(for: try signedFeed(), feedURL: feedURL, publicKey: "not base64!"))
    }

    func testSHA256OfFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try UpdateCheck.sha256(ofFile: url), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testShippingPublicKeyIsAValidKey() throws {
        // The Info.plist key must decode, or no install would ever verify.
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Info.plist")
        let dict = try XCTUnwrap(NSDictionary(contentsOf: plist))
        let key = try XCTUnwrap(dict["MEUpdatePublicKey"] as? String)
        XCTAssertNoThrow(try Curve25519.Signing.PublicKey(rawRepresentation: XCTUnwrap(Data(base64Encoded: key))))
    }
}
