import CryptoKit
import Foundation
import GRDB
import Testing
import Audit
import Store
import PurserTestSupport

@Suite struct AuditLogTests {
    private struct Payload: Encodable { var note: String }

    private func makeLog(_ database: WorkspaceDatabase, actor: String = "001234.synthetic-owner.0001") -> AuditLog {
        let clock = ManualClock(Sample.fixedNow)
        return AuditLog(database: database, actor: { actor }, now: { clock.advance(by: 1); return clock.now() })
    }

    @Test func firstEventChainsFromGenesis() throws {
        let log = makeLog(try WorkspaceDatabase.inMemory())
        let event = try log.append(.signIn, refs: [:], payload: Payload(note: "hello"))
        #expect(event.seq == 1)
        #expect(event.prevHash == String(repeating: "0", count: 64))
        #expect(event.payloadJSON == "{\"note\":\"hello\"}")
        let expected = SHA256.hash(data: Data("\(event.prevHash)|1|2026-10-09T12:00:01.000Z|signIn|001234.synthetic-owner.0001|{}|{\"note\":\"hello\"}".utf8))
            .map { String(format: "%02x", $0) }.joined()
        #expect(event.hash == expected)
        #expect(try log.head()?.seq == 1)
        #expect(try log.head()?.hash == expected)
    }

    @Test func eventsChainAndVerify() throws {
        let log = makeLog(try WorkspaceDatabase.inMemory())
        let first = try log.append(.workspaceOpened, refs: ["workspace": "ws-1"], payload: Payload(note: "a"))
        let second = try log.append(.syncStarted, refs: ["syncId": "1"], payload: Payload(note: "b"))
        try log.append(.syncFinished, refs: ["syncId": "1"], payload: Payload(note: "c"))
        #expect(second.prevHash == first.hash)
        #expect(try log.verifyChain() == .ok(count: 3))
        let page = try log.events(after: 1, limit: 1)
        #expect(page.map(\.seq) == [2])
        #expect(page.first?.refs == ["syncId": "1"])
        #expect(page.first?.type == .syncStarted)
        #expect(page.first?.ts == Date(timeIntervalSince1970: 1_791_547_202))
    }

    @Test func emptyLogVerifiesAndHasNoHead() throws {
        let log = makeLog(try WorkspaceDatabase.inMemory())
        #expect(try log.verifyChain() == .ok(count: 0))
        #expect(try log.head() == nil)
    }

    @Test(arguments: ["Bearer eyJhbGciOiJFUzI1NiJ9", "-----BEGIN PRIVATE KEY-----"])
    func refusesSecretsInPayloadRefsAndActor(_ secret: String) throws {
        let database = try WorkspaceDatabase.inMemory()
        let log = makeLog(database)
        #expect(throws: AuditError.secretInPayload) { try log.append(.httpSent, refs: [:], payload: Payload(note: secret)) }
        #expect(throws: AuditError.secretInPayload) { try log.append(.httpSent, refs: ["header": secret], payload: Payload(note: "x")) }
        #expect(throws: AuditError.secretInPayload) { try makeLog(database, actor: secret).append(.signIn, refs: [:], payload: Payload(note: "x")) }
        #expect(try log.verifyChain() == .ok(count: 0))
    }

    @Test func detectsARowRewrittenAfterDroppingTheTriggers() throws {
        let database = try WorkspaceDatabase.inMemory()
        let log = makeLog(database)
        for note in ["a", "b", "c"] { try log.append(.verify, refs: [:], payload: Payload(note: note)) }
        // Test-only tampering: an attacker with raw file access drops the guard triggers first.
        try database.writer.write { db in
            try db.execute(sql: "DROP TRIGGER audit_no_update")
            try db.execute(sql: "UPDATE audit_event SET payload_json = '{\"note\":\"forged\"}' WHERE seq = 2")
        }
        #expect(try log.verifyChain() == .broken(atSeq: 2))
    }

    @Test func detectsADeletedRow() throws {
        let database = try WorkspaceDatabase.inMemory()
        let log = makeLog(database)
        for note in ["a", "b", "c"] { try log.append(.verify, refs: [:], payload: Payload(note: note)) }
        try database.writer.write { db in
            try db.execute(sql: "DROP TRIGGER audit_no_delete")
            try db.execute(sql: "DELETE FROM audit_event WHERE seq = 2")
        }
        #expect(try log.verifyChain() == .broken(atSeq: 3))
    }

    @Test func exportWritesVerifiableJSONLWithoutSecrets() throws {
        let log = makeLog(try WorkspaceDatabase.inMemory())
        try log.append(.syncStarted, refs: ["syncId": "1"], payload: Payload(note: "a"))
        try log.append(.syncFinished, refs: ["syncId": "1"], payload: Payload(note: "b"))
        let url = try makeTemporaryDirectory().appendingPathComponent("audit.jsonl")
        #expect(try log.exportJSONL(to: url) == 2)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 2)
        #expect(!text.contains("Bearer"))
        #expect(try AuditLog.verifyExport(at: url) == .ok(count: 2))
    }

    @Test func detectsACraftedExport() throws {
        let log = makeLog(try WorkspaceDatabase.inMemory())
        try log.append(.syncStarted, refs: [:], payload: Payload(note: "a"))
        try log.append(.syncFinished, refs: [:], payload: Payload(note: "b"))
        let url = try makeTemporaryDirectory().appendingPathComponent("audit.jsonl")
        try log.exportJSONL(to: url)
        let original = try String(contentsOf: url, encoding: .utf8)
        try original.replacingOccurrences(of: "\\\"b\\\"", with: "\\\"z\\\"").write(to: url, atomically: true, encoding: .utf8)
        #expect(try AuditLog.verifyExport(at: url) == .broken(atSeq: 2))
    }

    @Test func appendInsideCallerTransactionRollsBackWithIt() throws {
        let database = try WorkspaceDatabase.inMemory()
        let log = makeLog(database)
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try database.writer.write { db in
                try log.append(.configChanged, refs: [:], payload: Payload(note: "x"), in: db)
                throw Boom()
            }
        }
        #expect(try log.head() == nil)
    }
}
