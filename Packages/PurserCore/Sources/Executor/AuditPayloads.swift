import Foundation
import Domain
import ASCClient

struct PlanStatePayload: Encodable, Sendable {
    var from: String
    var to: String
    var pause: String?
    var endReason: String?
    var note: String?
}

struct ItemStatePayload: Encodable, Sendable {
    var from: String
    var to: String
    var ascId: String?
    var note: String?
}

/// Written before the request leaves. Never contains headers; the body holds ids and dates only.
struct HTTPSentPayload: Encodable, Sendable {
    var method: String
    var path: String
    var op: String
    var naturalKey: String
    var attempt: Int
    var body: String?
    /// Spec §5: the key id and the token's jti identify the credential; the token itself is never stored.
    var keyId: String
    var jti: String
}

struct HTTPReceivedPayload: Encodable, Sendable {
    var method: String
    var path: String
    var status: Int?
    var outcome: String
    var ascId: String?
    var error: ErrorInfo?

    enum CodingKeys: String, CodingKey { case method, path, status, outcome, ascId, error }

    /// K3: `status` is always present, null when the client returned success without a status code.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(method, forKey: .method)
        try container.encode(path, forKey: .path)
        try container.encode(status, forKey: .status)
        try container.encode(outcome, forKey: .outcome)
        try container.encodeIfPresent(ascId, forKey: .ascId)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

struct VerifyPayload: Encodable, Sendable {
    var product: String
    var attempt: Int
    var verified: [Int]
    var missing: [Int]
    var late: Bool
}

struct ConfirmationPayload: Encodable, Sendable {
    var level: Int
    var accepted: Bool
    var problems: [String]
    var reason: String?
    var acknowledgedExclusions: Bool
    var checkedRiskClasses: [String]
    var riskClasses: [String: Int]
    var verdictHash: String
    var verdictHashChanged: Bool
    /// Exceptions the confirmed plan passed through (S10a); omitted when there are none.
    var exceptions: [String]?
}

/// Raw ASC error as stored in item.error_json and in the audit.
struct ErrorInfo: Codable, Hashable, Sendable {
    var kind: String
    var status: Int?
    var code: String?
    var title: String?
    var detail: String?

    /// Identity of an error for the SYSTEMIC streak (spec §6: the same error three times in a row).
    var signature: String { "\(kind)|\(status.map(String.init) ?? "-")|\(code ?? "-")" }
}

extension ErrorInfo {
    init(_ error: ASCError) {
        switch error {
        case let .http(status, code, title, detail):
            self.init(kind: "http", status: status, code: code, title: title, detail: detail)
        case .rateLimited:
            self.init(kind: "rateLimited", status: 429, code: "RATE_LIMIT_EXCEEDED", title: nil, detail: nil)
        case let .network(description, maybeSent):
            self.init(kind: maybeSent ? "networkMaybeSent" : "networkNotSent", status: nil, code: nil, title: nil, detail: description)
        case let .decoding(message):
            self.init(kind: "decoding", status: nil, code: nil, title: nil, detail: message)
        case let .foreignResource(message):
            self.init(kind: "foreignResource", status: nil, code: nil, title: nil, detail: message)
        case .readOnlyClient:
            self.init(kind: "readOnlyClient", status: nil, code: nil, title: nil, detail: nil)
        }
    }
}
