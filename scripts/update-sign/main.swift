// Release-signing helper, built by scripts/update-key.sh and scripts/package-release.sh together
// with Sources/MarkdownCore/UpdateFeed.swift (so the signed message format has one definition).
//
//   update-sign generate                         new private key (base64) on stdout — pipe it, never print it
//   update-sign public                           public key for $MARKDOWN_EDITOR_UPDATE_KEY
//   update-sign sign <version> <sha256>          signature for $MARKDOWN_EDITOR_UPDATE_KEY
//   update-sign verify <version> <sha256> <signature> <public-key>   exit 0 if valid
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("update-sign: \(message)\n".utf8))
    exit(1)
}

func privateKey() -> Curve25519.Signing.PrivateKey {
    guard let b64 = ProcessInfo.processInfo.environment["MARKDOWN_EDITOR_UPDATE_KEY"], !b64.isEmpty,
          let data = Data(base64Encoded: b64),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
        fail("MARKDOWN_EDITOR_UPDATE_KEY is missing or not a base64 Ed25519 private key")
    }
    return key
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "generate":
    print(Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString())
case "public":
    print(privateKey().publicKey.rawRepresentation.base64EncodedString())
case "sign" where args.count == 3:
    let key = privateKey().rawRepresentation.base64EncodedString()
    do { print(try UpdateSignature.sign(version: args[1], sha256: args[2], privateKey: key)) } catch { fail("\(error)") }
case "verify" where args.count == 5:
    exit(UpdateSignature.isValid(signature: args[3], version: args[1], sha256: args[2], publicKey: args[4]) ? 0 : 1)
default:
    fail("usage: update-sign generate | public | sign <version> <sha256> | verify <version> <sha256> <signature> <public-key>")
}
