import Foundation
import Domain
import ASCClient
import Catalog

/// Spec §4: optional Slack messages per workspace (new findings, apply finished or paused). The texts carry counts, states
/// and rule ids only: never prices, product ids or asc ids.
public struct SlackNotifier: Sendable {
    let transport: any HTTPTransport

    public init(transport: any HTTPTransport) { self.transport = transport }

    public static func applyFinished(workspace: String, state: PlanState, done: Int, total: Int) -> String {
        "Purser · \(workspace): Apply \(state.rawValue) (\(done)/\(total))"
    }

    public static func applyPaused(workspace: String, reason: PauseReason, done: Int, total: Int) -> String {
        "Purser · \(workspace): apply paused (\(reason.rawValue.uppercased())) at \(done)/\(total)"
    }

    /// Groups by rule id, or by finding type when the finding has no rule (EXTERNAL, SCHEDULE_BROKEN).
    public static func newFindings(workspace: String, findings: [FindingRecord]) -> String {
        var counts: [String: Int] = [:]
        for finding in findings { counts[finding.rule?.rawValue ?? finding.type.rawValue, default: 0] += 1 }
        let parts = counts.sorted { $0.key < $1.key }.map { "\($0.key) × \($0.value)" }.joined(separator: ", ")
        return "Purser · \(workspace): \(findings.count) new findings (\(parts))"
    }

    public func publish(text: String, webhook: URL) async throws {
        guard SlackWebhook.isValid(webhook) else { throw SlackPublishError.invalidWebhook }
        var request = URLRequest(url: webhook)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text], options: [.sortedKeys])
        let (_, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else { throw SlackPublishError.http(response.statusCode) }
    }
}
