import CryptoKit
import Foundation
import Audit
import ASCClient
import Domain

/// One part of an upload a reservation asks for (`uploadOperations` of an App Store review screenshot).
public struct UploadOperation: Hashable, Sendable {
    public var method: String
    public var url: URL
    public var offset: Int
    public var length: Int
    public var headers: [String: String]

    public init(method: String, url: URL, offset: Int, length: Int, headers: [String: String]) {
        self.method = method; self.url = url; self.offset = offset; self.length = length; self.headers = headers
    }

    /// The operations of a reservation (POST …AppStoreReviewScreenshots); nil when one of them lacks a method, a URL,
    /// an offset or a length.
    public static func list(from resource: JSONAPIResource) -> [UploadOperation]? {
        guard case let .array(entries)? = resource.attributes["uploadOperations"] else { return nil }
        var operations: [UploadOperation] = []
        for entry in entries {
            guard case let .object(fields) = entry, let method = fields["method"]?.stringValue,
                  let url = fields["url"]?.stringValue.flatMap(URL.init(string:)),
                  let offset = fields["offset"]?.intValue, let length = fields["length"]?.intValue else { return nil }
            var headers: [String: String] = [:]
            if case let .array(items)? = fields["requestHeaders"] {
                for item in items {
                    if case let .object(header) = item, let name = header["name"]?.stringValue, let value = header["value"]?.stringValue {
                        headers[name] = value
                    }
                }
            }
            operations.append(UploadOperation(method: method, url: url, offset: offset, length: length, headers: headers))
        }
        return operations
    }
}

public enum AssetTransferError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Not https, not an Apple host, or a response that came from another URL. Scheme and host only: a pre-signed URL
    /// carries its secret in the path or the query.
    case refusedURL(String)
    case noImage
    case badOperation(String)
    case http(status: Int, host: String)
    /// A transport failure as the domain and code of its error, never its text (which can hold the URL).
    case network(String)

    public var description: String {
        switch self {
        case let .refusedURL(url): return "refused \(url): only https to an Apple host (*.apple.com, *.mzstatic.com)"
        case .noImage: return "the source has no finished review screenshot to copy"
        case let .badOperation(detail): return "unusable upload operation: \(detail)"
        case let .http(status, host): return "HTTP \(status) from \(host)"
        case let .network(detail): return "network: \(detail)"
        }
    }
}

/// Written before a part leaves. Scheme and host only: the path of a pre-signed URL can carry a secret, and the bytes of
/// the image are never recorded.
struct AssetSentPayload: Encodable, Sendable {
    var method: String
    var scheme: String
    var host: String
    var part: Int
    var offset: Int
    var length: Int
}

struct AssetReceivedPayload: Encodable, Sendable {
    var method: String
    var scheme: String
    var host: String
    var part: Int
    var status: Int?
    var error: String?

    enum CodingKeys: String, CodingKey { case method, scheme, host, part, status, error }

    /// `status` is always present (null when no HTTP status came back), as in the other HTTP_RECEIVED payloads.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(method, forKey: .method)
        try container.encode(scheme, forKey: .scheme)
        try container.encode(host, forKey: .host)
        try container.encode(part, forKey: .part)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

/// The only code that talks to an Apple host other than api.appstoreconnect.apple.com (spec "Localizations and cloning"
/// §3): it downloads a review screenshot from Apple's image CDN and uploads a copy to the URLs of a reservation. Only
/// https to *.apple.com and *.mzstatic.com, never an Authorization header or a cookie, and every upload PUT between a
/// committed HTTP_SENT and an HTTP_RECEIVED like any write. The reservation is Apple's data and treated as hostile: every
/// operation is checked before the first byte leaves, and a URL never reaches the audit or a message beyond scheme and
/// host. The app obtains it through `live`, whose transport refuses redirects; tests may build it with a transport of
/// their own (ArchitectureTests).
public struct AssetTransfer: Sendable {
    public static let allowedHostSuffixes = [".apple.com", ".mzstatic.com"]

    /// The characters of a plain host name, lowercase.
    private static let hostCharacters = Set<Unicode.Scalar>("abcdefghijklmnopqrstuvwxyz0123456789-.".unicodeScalars)

    /// The characters of an HTTP token (RFC 7230), the form of a header name.
    private static let tokenCharacters = Set<Unicode.Scalar>(
        "!#$%&'*+-.^_`|~abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".unicodeScalars)

    private let transport: any HTTPTransport
    private let audit: AuditLog

    /// Package only: tests build it over a transport of their own; the app gets an AssetTransfer through `live` alone.
    package init(transport: any HTTPTransport, audit: AuditLog) {
        self.transport = transport
        self.audit = audit
    }

    /// The transfer the app uses: its transport has a session of its own that refuses every redirect and keeps no cookies,
    /// credentials or cache.
    public static func live(audit: AuditLog) -> AssetTransfer {
        AssetTransfer(transport: RedirectRefusingTransport(), audit: audit)
    }

    /// https, no user or password, and a plain host name (letters, digits, `-`, `.`) that ends in an allowed suffix. The
    /// host is read both decoded and as sent, and the two must agree: `evil.com%2F.apple.com` decodes to a host that ends
    /// in `.apple.com`, and a `%` is not a plain host character.
    public static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host(percentEncoded: true)?.lowercased(), host == url.host?.lowercased(),
              host.unicodeScalars.allSatisfy(hostCharacters.contains) else { return false }
        return allowedHostSuffixes.contains { host.hasSuffix($0) }
    }

    /// The image of a screenshot: `{w}` and `{h}` from its size, `{f}` = png. nil without a template or a size.
    public static func imageURL(_ screenshot: ReviewScreenshot) -> URL? {
        guard let template = screenshot.templateURL, let width = screenshot.width, let height = screenshot.height,
              width > 0, height > 0 else { return nil }
        return URL(string: template.replacingOccurrences(of: "{w}", with: String(width))
            .replacingOccurrences(of: "{h}", with: String(height))
            .replacingOccurrences(of: "{f}", with: "png"))
    }

    /// The checksum the commit (`PATCH uploaded=true`) sends: the MD5 of the whole file in lowercase hex.
    public static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Downloads the image of a screenshot as PNG. A read: no audit event.
    public func download(_ screenshot: ReviewScreenshot) async throws -> Data {
        guard let url = Self.imageURL(screenshot) else { throw AssetTransferError.noImage }
        guard Self.isAllowed(url) else { throw AssetTransferError.refusedURL(Self.redacted(url)) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        let (data, response) = try await exchange(request)
        try Self.requireAllowedSource(of: response)
        guard (200..<300).contains(response.statusCode) else {
            throw AssetTransferError.http(status: response.statusCode, host: url.host ?? "")
        }
        guard !data.isEmpty else { throw AssetTransferError.noImage }
        return data
    }

    /// Sends each part of `data` as the reservation asks. Every operation is checked before the first one is sent: it must
    /// be a PUT to an allowed URL with plain headers, and together the operations must cover the file exactly once.
    public func upload(_ data: Data, operations: [UploadOperation], refs: [String: String]) async throws {
        let parts = try Self.validated(data, operations)
        for (index, part) in parts.enumerated() {
            try await put(part.body, part.operation, part: index + 1,
                          refs: refs.merging(["part": String(index + 1)]) { current, _ in current })
        }
    }

    private static func validated(_ data: Data, _ operations: [UploadOperation]) throws -> [(operation: UploadOperation, body: Data)] {
        guard !operations.isEmpty else { throw AssetTransferError.badOperation("the reservation has no operations") }
        var parts: [(operation: UploadOperation, body: Data)] = []
        for operation in operations {
            guard operation.method.uppercased() == "PUT" else { throw AssetTransferError.badOperation("a part is not a PUT") }
            guard isAllowed(operation.url) else { throw AssetTransferError.refusedURL(redacted(operation.url)) }
            for (name, value) in operation.headers {
                guard !name.isEmpty, name.unicodeScalars.allSatisfy(tokenCharacters.contains) else {
                    throw AssetTransferError.badOperation("a header name is not an HTTP token")
                }
                guard !value.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) else {
                    throw AssetTransferError.badOperation("a header value holds a line break or a NUL")
                }
            }
            // Subtractions only: offset and length come from Apple and may be anything, so offset + length could overflow.
            guard operation.offset >= 0, operation.length > 0, operation.offset <= data.count,
                  operation.length <= data.count - operation.offset else {
                throw AssetTransferError.badOperation("bytes \(operation.offset) + \(operation.length) of \(data.count)")
            }
            let lower = data.startIndex + operation.offset
            parts.append((operation, data.subdata(in: lower..<(lower + operation.length))))
        }
        var covered = 0
        for operation in operations.sorted(by: { $0.offset < $1.offset }) {
            guard operation.offset == covered else { throw AssetTransferError.badOperation("the parts do not cover the file exactly once") }
            covered += operation.length   // never above data.count: each part fits the file and the parts do not overlap
        }
        guard covered == data.count else { throw AssetTransferError.badOperation("the parts cover \(covered) of \(data.count) bytes") }
        return parts
    }

    /// Headers a reservation could ask for that carry a credential or a cookie, or that frame the request itself: never
    /// sent, whatever the reservation says. The headers of real reservations are still to be recorded by spike SL10n (Q5);
    /// with them this can become an allow-list.
    private static func isWithheldHeader(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        return lowercased.hasPrefix("proxy-")
            || ["authorization", "cookie", "host", "connection", "transfer-encoding", "te", "upgrade"].contains(lowercased)
    }

    private func put(_ body: Data, _ operation: UploadOperation, part: Int, refs: [String: String]) async throws {
        let scheme = operation.url.scheme?.lowercased() ?? ""
        let host = operation.url.host ?? ""
        var request = URLRequest(url: operation.url)
        request.httpMethod = "PUT"
        request.httpShouldHandleCookies = false
        for (name, value) in operation.headers where !Self.isWithheldHeader(name) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = body
        try audit.append(.httpSent, refs: refs, payload: AssetSentPayload(method: "PUT", scheme: scheme, host: host, part: part,
                                                                         offset: operation.offset, length: operation.length))
        var status: Int?
        do {
            let (_, response) = try await exchange(request)
            status = response.statusCode
            try Self.requireAllowedSource(of: response)
            guard (200..<300).contains(response.statusCode) else { throw AssetTransferError.http(status: response.statusCode, host: host) }
            try audit.append(.httpReceived, refs: refs, payload: AssetReceivedPayload(method: "PUT", scheme: scheme, host: host, part: part,
                                                                                     status: response.statusCode, error: nil))
        } catch let error as AssetTransferError {
            try audit.append(.httpReceived, refs: refs, payload: AssetReceivedPayload(method: "PUT", scheme: scheme, host: host, part: part,
                                                                                     status: status, error: error.description))
            throw error
        }
    }

    private func exchange(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch {
            // Domain and code only: the text of an error can hold the URL, query included.
            let described = error as NSError
            throw AssetTransferError.network("\(described.domain) \(described.code)")
        }
    }

    /// Fails closed: a response without a URL, or from a URL that is not allowed, did not come from an Apple host.
    private static func requireAllowedSource(of response: HTTPURLResponse) throws {
        guard let source = response.url, isAllowed(source) else {
            throw AssetTransferError.refusedURL(response.url.map(redacted) ?? "an unknown URL")
        }
    }

    /// Scheme and host: the path and the query of a pre-signed URL never reach a message or the audit.
    static func redacted(_ url: URL) -> String { "\(url.scheme ?? "")://\(url.host(percentEncoded: true) ?? "")" }
}
