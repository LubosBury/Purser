import Foundation
import Testing
import Store
import Audit
import ASCClient
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

private func auditWithOneEvent() throws -> AuditLog {
    let log = AuditLog(database: try WorkspaceDatabase.inMemory(), actor: { "tester@example.com" },
                       now: { Date(timeIntervalSince1970: 1_790_000_000) })
    try log.append(.syncStarted, refs: [:], payload: ["trigger": "manual"])
    return log
}

private let webhook = URL(string: "https://hooks.slack.com/services/T0000/B0000/SYNTHETIC")!

@Suite("Slack chain head")
struct SlackChainHeadPublisherTests {
    @Test func postsOnlySeqAndHashAndRecordsTheEvent() async throws {
        let log = try auditWithOneEvent()
        let head = try #require(try log.head())
        let transport = RecordingTransport(status: 200)
        #expect(try await SlackChainHeadPublisher(transport: transport, audit: log).publish(webhook: webhook))
        let sent = try #require(await transport.recorded().first)
        #expect(sent.httpMethod == "POST")
        let body = try #require(try JSONSerialization.jsonObject(with: sent.httpBody ?? Data()) as? [String: String])
        #expect(body == ["text": "Purser audit chain head: seq \(head.seq), hash \(head.hash)"])
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
        let last = try #require(try log.events(after: 0, limit: 100).last)
        #expect(last.type == .chainHeadPublished)
        #expect(!last.payloadJSON.contains("hooks.slack.com"))
        #expect(!last.payloadJSON.contains("SYNTHETIC"))
    }

    @Test func refusesNonSlackWebhooksWithoutSending() async throws {
        let transport = RecordingTransport(status: 200)
        let publisher = SlackChainHeadPublisher(transport: transport, audit: try auditWithOneEvent())
        await #expect(throws: SlackPublishError.invalidWebhook) { try await publisher.publish(webhook: URL(string: "https://example.com/hook")!) }
        await #expect(throws: SlackPublishError.invalidWebhook) { try await publisher.publish(webhook: URL(string: "http://hooks.slack.com/services/x")!) }
        #expect(await transport.recorded().isEmpty)
    }

    @Test func failedPostRecordsNoEvent() async throws {
        let log = try auditWithOneEvent()
        let before = try log.events(after: 0, limit: 100).count
        await #expect(throws: SlackPublishError.http(500)) {
            try await SlackChainHeadPublisher(transport: RecordingTransport(status: 500), audit: log).publish(webhook: webhook)
        }
        #expect(try log.events(after: 0, limit: 100).count == before)
    }
}
