import Foundation
import Domain
import Store
import Audit
import Catalog

/// Findings of one rule on one product (Findings screen: "I4 intro ≥ regular price · 148 cells").
public struct FindingGroup: Hashable, Sendable, Identifiable {
    public var type: FindingType
    public var rule: RuleID?
    public var productAscId: String
    public var findings: [FindingRecord]           // sorted by cell storage key

    public init(type: FindingType, rule: RuleID?, productAscId: String, findings: [FindingRecord]) {
        self.type = type; self.rule = rule; self.productAscId = productAscId; self.findings = findings
    }

    public var id: String { "\(type.rawValue)|\(rule?.rawValue ?? "-")|\(productAscId)" }
    public var cellCount: Int { Set(findings.map(\.cell)).count }
    public var findingIds: [Int64] { findings.map(\.id) }
    public var territories: Set<TerritoryCode> { Set(findings.compactMap(\.cell.territory)) }
}

public enum FindingGroups {
    public static func group(_ findings: [FindingRecord]) -> [FindingGroup] {
        let grouped = Dictionary(grouping: findings) { "\($0.type.rawValue)|\($0.rule?.rawValue ?? "-")|\($0.cell.productAscId)" }
        return grouped.values.map { records in
            let sorted = records.sorted { $0.cell.storageKey < $1.cell.storageKey }
            return FindingGroup(type: sorted[0].type, rule: sorted[0].rule, productAscId: sorted[0].cell.productAscId, findings: sorted)
        }
        .sorted { ($0.rule?.rawValue ?? "", $0.productAscId, $0.type.rawValue) < ($1.rule?.rawValue ?? "", $1.productAscId, $1.type.rawValue) }
    }
}

public enum FindingAckError: Error, Equatable {
    case reasonTooShort(minimum: Int)
}

/// Ack with a mandatory reason; every ack is audited (findingAcked).
public struct FindingAcknowledger: Sendable {
    public static let minimumReasonLength = 5
    private let catalog: CatalogStore
    private let audit: AuditLog
    private let now: @Sendable () -> Date

    public init(catalog: CatalogStore, audit: AuditLog, now: @escaping @Sendable () -> Date) {
        self.catalog = catalog; self.audit = audit; self.now = now
    }

    public func ack(findingIds: [Int64], reason: String) throws {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minimumReasonLength else { throw FindingAckError.reasonTooShort(minimum: Self.minimumReasonLength) }
        let at = now()
        for id in findingIds {
            try catalog.ack(findingId: id, reason: trimmed, at: at)
            try audit.append(.findingAcked, refs: ["finding": String(id)], payload: ["reason": trimmed])
        }
    }
}

/// Runs the invariants after every sync that did not fail and returns the new INVARIANT findings.
public struct PostSyncChecks: Sendable {
    private let runner: InvariantRunner
    private let catalog: CatalogStore
    private let now: @Sendable () -> Date

    public init(runner: InvariantRunner, catalog: CatalogStore, now: @escaping @Sendable () -> Date) {
        self.runner = runner; self.catalog = catalog; self.now = now
    }

    public func afterSync(status: SyncStatus) throws -> [FindingRecord] {
        guard status != .failed, let snapshot = try catalog.latestSnapshot() else { return [] }
        return try runner.run(snapshot: snapshot, today: CalendarDate.today(now: now()))
    }
}
