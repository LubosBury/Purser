import Foundation
import GRDB
import Domain
import Store

/// Read-only queries over the K2 schema that the nightly runner needs.
struct WorkspaceStateReader {
    let database: WorkspaceDatabase

    func config() throws -> WorkspaceConfig? {
        try database.writer.read { db in
            guard let json = try String.fetchOne(db, sql: "SELECT config_json FROM workspace LIMIT 1") else { return nil }
            return try JSONCoding.decode(WorkspaceConfig.self, from: json)
        }
    }

    /// Latest complete or partial sync of any trigger.
    func lastFinishedSync() throws -> Date? { try latestFinished(statuses: ["complete", "partial"]) }

    func lastCompleteSync() throws -> Date? { try latestFinished(statuses: ["complete"]) }

    func applyingHeartbeats() throws -> [Date?] {
        try database.writer.read { db in
            try String?.fetchAll(db, sql: "SELECT heartbeat_at FROM plan WHERE state = 'applying'").map { $0.flatMap(Self.parse) }
        }
    }

    private func latestFinished(statuses: [String]) throws -> Date? {
        try database.writer.read { db in
            let placeholders = statuses.map { _ in "?" }.joined(separator: ", ")
            let value = try String.fetchOne(db, sql: """
                SELECT finished_at FROM sync_run
                WHERE finished_at IS NOT NULL AND status IN (\(placeholders))
                ORDER BY id DESC LIMIT 1
                """, arguments: StatementArguments(statuses))
            return value.flatMap(Self.parse)
        }
    }

    static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
