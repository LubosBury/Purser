import Foundation
import Audit
import ASCClient

struct ChainHeadPayload: Encodable, Sendable {
    var seq: Int64
    var hash: String
    var destination: String
}

/// Daily audit fingerprint (spec §5): only the chain head's seq and hash leave the Mac, never prices or ids.
public struct SlackChainHeadPublisher: Sendable {
    let transport: any HTTPTransport
    let audit: AuditLog

    public init(transport: any HTTPTransport, audit: AuditLog) {
        self.transport = transport
        self.audit = audit
    }

    public static func message(seq: Int64, hash: String) -> String {
        "Purser audit chain head: seq \(seq), hash \(hash)"
    }

    /// Returns false when the audit is empty. The webhook URL (a secret) is never logged or audited.
    @discardableResult
    public func publish(webhook: URL) async throws -> Bool {
        guard SlackWebhook.isValid(webhook) else { throw SlackPublishError.invalidWebhook }
        guard let head = try audit.head() else { return false }
        var request = URLRequest(url: webhook)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": Self.message(seq: head.seq, hash: head.hash)],
                                                      options: [.sortedKeys])
        let (_, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else { throw SlackPublishError.http(response.statusCode) }
        try audit.append(.chainHeadPublished, refs: [:], payload: ChainHeadPayload(seq: head.seq, hash: head.hash, destination: "slack"))
        return true
    }
}
