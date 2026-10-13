// Prints a GET-scoped ASC API token for one request. Spike helper; the app builds its tokens in JWTSigner.
// Usage: swift Tools/mint-token.swift --key-id KEYID [--issuer-id UUID] --p8 /path/AuthKey.p8 --path /v1/... [--query 'a=b&limit=200']
// Without --issuer-id (or with an empty one) the token is for an individual key ("sub": "user").
import CryptoKit
import Foundation

func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

guard let keyId = argument("--key-id"), let p8Path = argument("--p8"), let path = argument("--path") else {
    fail("usage: swift Tools/mint-token.swift --key-id KEYID [--issuer-id UUID] --p8 FILE --path /v1/... [--query QUERY]")
}
guard path.hasPrefix("/v1/") || path.hasPrefix("/v2/") else { fail("--path must start with /v1/ or /v2/") }
let issuerId = argument("--issuer-id") ?? ""
let query = argument("--query") ?? ""

// Same rule as ASCHTTPClient.scope(method:url:): drop limit, cursor and sort; keep everything else in order.
let kept = query.split(separator: "&").filter { item in
    let name = item.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
    return !["limit", "cursor", "sort"].contains(name)
}
let scope = "GET \(path)" + (kept.isEmpty ? "" : "?" + kept.joined(separator: "&"))

let pem: String
do { pem = try String(contentsOfFile: p8Path, encoding: .utf8) } catch { fail("cannot read --p8 file") }
guard let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else { fail("--p8 is not a P-256 private key") }

let now = Int(Date().timeIntervalSince1970)
var claims: [String: Any] = ["iat": now, "exp": now + 19 * 60, "aud": "appstoreconnect-v1", "scope": [scope]]
if issuerId.isEmpty { claims["sub"] = "user" } else { claims["iss"] = issuerId }
let header: [String: Any] = ["alg": "ES256", "kid": keyId, "typ": "JWT"]
let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
let input = base64URL(try JSONSerialization.data(withJSONObject: header, options: options)) + "."
    + base64URL(try JSONSerialization.data(withJSONObject: claims, options: options))
let signature = try key.signature(for: Data(input.utf8))
print(input + "." + base64URL(signature.rawRepresentation))
