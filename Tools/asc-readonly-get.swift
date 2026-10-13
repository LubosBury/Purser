#!/usr/bin/env swift
// Read-only App Store Connect request tool for key spikes (S9). Sends exactly one GET with a GET-scoped token.
// The JWT is minted in memory and never printed or written anywhere. It can never mint an unscoped
// (write-capable) token: the scope is always a "GET /v1/..." or "GET /v2/..." entry.
//
// Usage (from the repository root):
//   swift Tools/asc-readonly-get.swift --key <AuthKey_X.p8> --key-id <KEY_ID> [--issuer <ISSUER_ID>]
//       [--scope "GET <path>[?query]"] [--out <file>] [--replace <from>=<to>]... <path-with-query>
//
// --issuer      team key (JWT "iss"); without it the token is for an individual key (JWT "sub": "user")
// --scope       JWT "scope" = [<value>] instead of the default (to test a mismatching scope); must start with
//               "GET /v1/" or "GET /v2/"
//               default: the scope Purser's read client sends, "GET <path>?<query without limit, cursor, sort>"
// --out         write the response body to a file instead of stdout
// --replace     replace a literal string in the response body (anonymisation); split at the last "="
// Exit status: 0 = HTTP 200, 1 = other HTTP status, 2 = usage or local error.
import CryptoKit
import Foundation

struct Options {
    var keyPath = ""
    var keyId = ""
    var issuer: String?
    var explicitScope: String?
    var outPath: String?
    var replacements: [(from: String, to: String)] = []
    var pathAndQuery = ""
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(2)
}

func isGETScope(_ value: String) -> Bool {
    value.hasPrefix("GET /v1/") || value.hasPrefix("GET /v2/")
}

func parseOptions(_ arguments: [String]) -> Options {
    var options = Options()
    var index = 0
    func nextValue() -> String {
        index += 1
        guard index < arguments.count else { fail("missing value for \(arguments[index - 1])") }
        return arguments[index]
    }
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--key": options.keyPath = nextValue()
        case "--key-id": options.keyId = nextValue()
        case "--issuer": options.issuer = nextValue()
        case "--scope":
            let value = nextValue()
            guard isGETScope(value) else { fail("--scope must start with \"GET /v1/\" or \"GET /v2/\"") }
            options.explicitScope = value
        case "--out": options.outPath = nextValue()
        case "--replace":
            let pair = nextValue()
            guard let separator = pair.lastIndex(of: "="), separator != pair.startIndex else {
                fail("--replace expects <from>=<to>")
            }
            options.replacements.append((String(pair[..<separator]), String(pair[pair.index(after: separator)...])))
        default:
            guard options.pathAndQuery.isEmpty, argument.hasPrefix("/") else { fail("unexpected argument \(argument)") }
            options.pathAndQuery = argument
        }
        index += 1
    }
    guard !options.keyPath.isEmpty, !options.keyId.isEmpty, !options.pathAndQuery.isEmpty else {
        fail("usage: swift Tools/asc-readonly-get.swift --key <file.p8> --key-id <KEY_ID> [--issuer <ID>] [--scope \"GET /v1/...\"] [--out <file>] [--replace <from>=<to>]... /v1/...")
    }
    guard options.pathAndQuery.hasPrefix("/v1/") || options.pathAndQuery.hasPrefix("/v2/") else {
        fail("path must start with /v1/ or /v2/")
    }
    let keyFile = URL(fileURLWithPath: options.keyPath).standardizedFileURL.path
    let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.path
    guard !keyFile.hasPrefix(workingDirectory + "/") else {
        fail("refusing a key stored inside \(workingDirectory); keep .p8 files in ~/PurserSecrets")
    }
    return options
}

/// The scope Purser's read client puts into its token (ASCHTTPClient.scope(method:url:), Tools/mint-token.swift):
/// "GET <path>" plus the query without limit, cursor and sort, other items kept in order.
func readClientScope(for pathAndQuery: String) -> String {
    let parts = pathAndQuery.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
    let path = String(parts[0])
    let query = parts.count > 1 ? String(parts[1]) : ""
    let kept = query.split(separator: "&").filter { item in
        let name = item.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
        return !["limit", "cursor", "sort"].contains(name)
    }
    return "GET \(path)" + (kept.isEmpty ? "" : "?" + kept.joined(separator: "&"))
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func makeToken(options: Options, privateKeyPEM: String, scope: [String]) throws -> String {
    precondition(!scope.isEmpty && scope.allSatisfy(isGETScope), "only GET-scoped tokens may be minted")
    let now = Int(Date().timeIntervalSince1970)
    var payload: [String: Any] = ["aud": "appstoreconnect-v1", "iat": now, "exp": now + 600, "scope": scope]
    if let issuer = options.issuer { payload["iss"] = issuer } else { payload["sub"] = "user" }
    let header: [String: Any] = ["alg": "ES256", "kid": options.keyId, "typ": "JWT"]
    let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys, .withoutEscapingSlashes])
    let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
    let signingInput = base64URL(headerData) + "." + base64URL(payloadData)
    let key = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)
    let signature = try key.signature(for: Data(signingInput.utf8))
    return signingInput + "." + base64URL(signature.rawRepresentation)
}

let options = parseOptions(Array(CommandLine.arguments.dropFirst()))

let privateKeyPEM: String
do {
    privateKeyPEM = try String(contentsOfFile: options.keyPath, encoding: .utf8)
} catch {
    fail("cannot read key file: \(error.localizedDescription)")
}

let scope = [options.explicitScope ?? readClientScope(for: options.pathAndQuery)]

let token: String
do {
    token = try makeToken(options: options, privateKeyPEM: privateKeyPEM, scope: scope)
} catch {
    fail("cannot sign token: \(error)")
}

guard let url = URL(string: "https://api.appstoreconnect.apple.com" + options.pathAndQuery) else { fail("invalid path") }
var request = URLRequest(url: url)
request.httpMethod = "GET"
request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
request.setValue("application/json", forHTTPHeaderField: "Accept")

let data: Data
let response: URLResponse
do {
    (data, response) = try await URLSession.shared.data(for: request)
} catch {
    fail("request failed: \(error.localizedDescription)")
}
guard let http = response as? HTTPURLResponse else { fail("no HTTP response") }

var report = "HTTP \(http.statusCode)\n"
report += "X-Rate-Limit: \(http.value(forHTTPHeaderField: "X-Rate-Limit") ?? "-")\n"
report += "token: " + (options.issuer == nil ? "individual (sub=user)" : "team (iss)")
report += ", scope=\(scope)\n"

var body = String(decoding: data, as: UTF8.self)
if let object = try? JSONSerialization.jsonObject(with: data),
   let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
    body = String(decoding: pretty, as: UTF8.self)
    if let document = object as? [String: Any] {
        if let resources = document["data"] as? [[String: Any]] {
            let ids = resources.compactMap { $0["id"] as? String }
            report += "data: \(resources.count) resource(s): \(ids.joined(separator: ", "))\n"
        } else if let resource = document["data"] as? [String: Any] {
            report += "data: 1 resource: \(resource["id"] as? String ?? "?")\n"
        }
        if let errors = document["errors"] as? [[String: Any]] {
            for error in errors {
                report += "error: \(error["status"] as? String ?? "?") \(error["code"] as? String ?? "?") \(error["title"] as? String ?? "")\n"
            }
        }
    }
}
for replacement in options.replacements {
    body = body.replacingOccurrences(of: replacement.from, with: replacement.to)
}
guard !body.contains("Bearer "), !body.contains("-----BEGIN") else {
    fail("response body contains a bearer token or a key; not writing it")
}

FileHandle.standardError.write(Data(report.utf8))
if let outPath = options.outPath {
    do {
        try body.write(toFile: outPath, atomically: true, encoding: .utf8)
    } catch {
        fail("cannot write \(outPath): \(error.localizedDescription)")
    }
    FileHandle.standardError.write(Data("body written to \(outPath)\n".utf8))
} else {
    print(body)
}
exit(http.statusCode == 200 ? 0 : 1)
