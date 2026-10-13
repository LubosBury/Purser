import CryptoKit
import Foundation
import GRDB
import Store

public enum AuditEventType: String, Codable, Sendable {
    case signIn, workspaceOpened, configChanged
    case syncStarted, syncFinished, findingRaised, findingAcked
    case planCreated, planStateChanged, confirmation, warningShown
    case httpSent, httpReceived, itemStateChanged, verify
    case exportPerformed, chainHeadPublished
    /// A tool call that came over the MCP bridge and changes something (a draft, an ack, a sync, a write to ASC).
    case mcpToolCalled
}

public struct AuditEvent: Hashable, Sendable, Codable {
    public var seq: Int64
    public var ts: Date
    public var type: AuditEventType
    public var actor: String
    public var refs: [String: String]
    public var payloadJSON: String
    public var prevHash: String
    public var hash: String

    public init(seq: Int64, ts: Date, type: AuditEventType, actor: String, refs: [String: String],
                payloadJSON: String, prevHash: String, hash: String) {
        self.seq = seq; self.ts = ts; self.type = type; self.actor = actor; self.refs = refs
        self.payloadJSON = payloadJSON; self.prevHash = prevHash; self.hash = hash
    }
}

public enum ChainVerification: Equatable, Sendable { case ok(count: Int), broken(atSeq: Int64) }
public enum AuditError: Error, Equatable { case secretInPayload }

/// Genesis prevHash = 64 × "0". hash = sha256hex(prevHash|seq|ts|type|actor|refsJSON|payloadJSON), sortedKeys JSON.
public struct AuditLog: Sendable {
    public static let genesisHash = String(repeating: "0", count: 64)
    /// Substrings that must never reach the audit log (bearer tokens, PEM keys).
    static let forbiddenSubstrings = ["Bearer ", "-----BEGIN"]

    private let database: WorkspaceDatabase
    private let actor: @Sendable () -> String
    private let now: @Sendable () -> Date

    public init(database: WorkspaceDatabase, actor: @escaping @Sendable () -> String, now: @escaping @Sendable () -> Date) {
        self.database = database
        self.actor = actor
        self.now = now
    }

    @discardableResult
    public func append<P: Encodable>(_ type: AuditEventType, refs: [String: String], payload: P) throws -> AuditEvent {
        try database.writer.write { db in
            try append(type, refs: refs, payload: payload, in: db)
        }
    }

    @discardableResult
    public func append<P: Encodable>(_ type: AuditEventType, refs: [String: String], payload: P, in db: Database) throws -> AuditEvent {
        let actorValue = actor()
        let refsJSON = try JSONCoding.string(refs)
        let payloadJSON = try JSONCoding.string(payload)
        for text in [actorValue, refsJSON, payloadJSON] where Self.containsSecret(text) {
            throw AuditError.secretInPayload
        }
        let last = try Row.fetchOne(db, sql: "SELECT seq, hash FROM audit_event ORDER BY seq DESC LIMIT 1")
        let lastSeq: Int64 = last?["seq"] ?? 0
        let prevHash: String = last?["hash"] ?? Self.genesisHash
        let line = ChainLine(seq: lastSeq + 1, ts: Timestamp.string(now()), type: type.rawValue, actor: actorValue,
                             refs: refsJSON, payload: payloadJSON, prevHash: prevHash, hash: "")
        let hash = line.computedHash
        try db.execute(
            sql: "INSERT INTO audit_event (seq, ts, type, actor, refs_json, payload_json, prev_hash, hash) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            arguments: [line.seq, line.ts, line.type, line.actor, line.refs, line.payload, line.prevHash, hash])
        return AuditEvent(seq: line.seq, ts: try Timestamp.date(line.ts), type: type, actor: actorValue, refs: refs,
                          payloadJSON: payloadJSON, prevHash: prevHash, hash: hash)
    }

    public func verifyChain() throws -> ChainVerification {
        let lines = try database.writer.read { db in try Self.fetchLines(db, after: 0, limit: nil) }
        return Self.verify(lines)
    }

    public func head() throws -> (seq: Int64, hash: String)? {
        try database.writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT seq, hash FROM audit_event ORDER BY seq DESC LIMIT 1") else { return nil }
            return (seq: row["seq"], hash: row["hash"])
        }
    }

    public func events(after seq: Int64, limit: Int) throws -> [AuditEvent] {
        try database.writer.read { db in
            try Self.fetchLines(db, after: seq, limit: limit).map { line in
                guard let type = AuditEventType(rawValue: line.type) else {
                    throw StoreError.corruptValue(table: "audit_event", column: "type", value: line.type)
                }
                return AuditEvent(seq: line.seq, ts: try Timestamp.date(line.ts), type: type, actor: line.actor,
                                  refs: try JSONCoding.decode([String: String].self, from: line.refs),
                                  payloadJSON: line.payload, prevHash: line.prevHash, hash: line.hash)
            }
        }
    }

    /// Writes one JSON object per line with the exact stored strings, so `verifyExport(at:)` can recheck the chain.
    /// The caller logs `exportPerformed` once the file reached its destination.
    @discardableResult
    public func exportJSONL(to url: URL) throws -> Int {
        let lines = try database.writer.read { db in try Self.fetchLines(db, after: 0, limit: nil) }
        var output = Data()
        for line in lines {
            output.append(try JSONCoding.encoder.encode(line))
            output.append(0x0A)
        }
        try output.write(to: url, options: .atomic)
        return lines.count
    }

    /// Verifies a file written by `exportJSONL(to:)` without any database.
    public static func verifyExport(at url: URL) throws -> ChainVerification {
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = try text.split(separator: "\n", omittingEmptySubsequences: true).map {
            try JSONCoding.decoder.decode(ChainLine.self, from: Data($0.utf8))
        }
        return verify(lines)
    }

    // MARK: - Internals

    static func containsSecret(_ text: String) -> Bool {
        forbiddenSubstrings.contains { text.contains($0) }
    }

    static func verify(_ lines: [ChainLine]) -> ChainVerification {
        var expectedPrev = genesisHash
        var expectedSeq: Int64 = 1
        for line in lines {
            guard line.seq == expectedSeq, line.prevHash == expectedPrev, line.hash == line.computedHash else {
                return .broken(atSeq: line.seq)
            }
            expectedPrev = line.hash
            expectedSeq += 1
        }
        return .ok(count: lines.count)
    }

    private static func fetchLines(_ db: Database, after seq: Int64, limit: Int?) throws -> [ChainLine] {
        let sql = "SELECT * FROM audit_event WHERE seq > ? ORDER BY seq" + (limit.map { " LIMIT \($0)" } ?? "")
        return try Row.fetchAll(db, sql: sql, arguments: [seq]).map { row in
            ChainLine(seq: row["seq"], ts: row["ts"], type: row["type"], actor: row["actor"], refs: row["refs_json"],
                      payload: row["payload_json"], prevHash: row["prev_hash"], hash: row["hash"])
        }
    }
}

/// One audit row exactly as stored; also the JSONL export format.
struct ChainLine: Codable, Equatable, Sendable {
    var seq: Int64
    var ts: String
    var type: String
    var actor: String
    var refs: String
    var payload: String
    var prevHash: String
    var hash: String

    var computedHash: String {
        let input = [prevHash, String(seq), ts, type, actor, refs, payload].joined(separator: "|")
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
