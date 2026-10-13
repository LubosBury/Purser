import Foundation
import Testing
import Domain
import ASCClient
import Catalog
import Executor

private actor RecordingTransport: HTTPTransport {
    private var requests: [URLRequest] = []
    let status: Int
    init(status: Int) { self.status = status }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (Data("ok".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
    func recorded() -> [URLRequest] { requests }
}

private func finding(_ id: Int64, _ type: FindingType, _ rule: RuleID?, _ subscription: String) -> FindingRecord {
    FindingRecord(id: id, type: type, rule: rule, cell: .regular(subscriptionId: subscription, territory: "USA", planType: .upfront),
                  fingerprint: "fp-\(id)", message: "synthetic finding \(id)", firstSync: 1, lastSync: 1,
                  planId: nil, ackReason: nil, ackAt: nil)
}

private let webhook = URL(string: "https://hooks.slack.com/services/T0000/B0000/SYNTHETIC")!

@Suite("Slack notifier")
struct SlackNotifierTests {
    @Test func messagesCarryOnlyCountsStatesAndRules() {
        #expect(SlackNotifier.applyFinished(workspace: "FruitJar", state: .scheduled, done: 12, total: 12)
                == "Purser · FruitJar: Apply scheduled (12/12)")
        #expect(SlackNotifier.applyPaused(workspace: "FruitJar", reason: .rate, done: 3, total: 12)
                == "Purser · FruitJar: apply paused (RATE) at 3/12")
        let text = SlackNotifier.newFindings(workspace: "FruitJar", findings: [
            finding(1, .invariant, "I4", "sub-y"), finding(2, .invariant, "I4", "sub-m"), finding(3, .external, nil, "sub-y")])
        #expect(text == "Purser · FruitJar: 3 new findings (EXTERNAL × 1, I4 × 2)")
        #expect(!text.contains("sub-"))
    }

    @Test func publishPostsOnlyTheTextToSlack() async throws {
        let transport = RecordingTransport(status: 200)
        try await SlackNotifier(transport: transport).publish(text: "Purser · FruitJar: Apply effective (1/1)", webhook: webhook)
        let sent = try #require(await transport.recorded().first)
        #expect(sent.httpMethod == "POST")
        let body = try #require(try JSONSerialization.jsonObject(with: sent.httpBody ?? Data()) as? [String: String])
        #expect(body == ["text": "Purser · FruitJar: Apply effective (1/1)"])
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func refusesOtherHostsAndReportsHTTPFailures() async throws {
        let transport = RecordingTransport(status: 200)
        await #expect(throws: SlackPublishError.invalidWebhook) {
            try await SlackNotifier(transport: transport).publish(text: "x", webhook: URL(string: "https://example.com/hook")!)
        }
        #expect(await transport.recorded().isEmpty)
        await #expect(throws: SlackPublishError.http(404)) {
            try await SlackNotifier(transport: RecordingTransport(status: 404)).publish(text: "x", webhook: webhook)
        }
    }
}
