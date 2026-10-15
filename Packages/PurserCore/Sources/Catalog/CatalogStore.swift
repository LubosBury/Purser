import CryptoKit
import Foundation
import GRDB
import Domain
import Store

public struct CatalogStore: Sendable {
    private let database: WorkspaceDatabase
    /// Shared by every copy of this store: its snapshots share one price point index until the price points change.
    private let pricePoints = PricePointCache()

    public init(database: WorkspaceDatabase) {
        self.database = database
    }

    /// The catalog as of the latest complete or partial sync; every (product, kind) scope shows the rows of the
    /// last sync that read it completely. nil before the first successful sync. The price points are the ones stored
    /// now; snapshots that see the same price points share one index.
    public func latestSnapshot() throws -> CatalogSnapshot? {
        try database.writer.read { db in
            guard let latest = try Row.fetchOne(db, sql: """
                SELECT id, started_at, finished_at FROM sync_run WHERE status IN ('complete', 'partial') ORDER BY id DESC LIMIT 1
                """) else { return nil }
            let syncId: Int64 = latest["id"]
            let takenAt = try Timestamp.date((latest["finished_at"] as String?) ?? latest["started_at"])

            var subscriptions: [String: SubscriptionInfo] = [:]
            var iaps: [String: IAPInfo] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT asc_id, kind, info_json FROM product WHERE last_sync >= ?", arguments: [syncId]) {
                let kind: String = row["kind"]
                if kind == ProductKind.subscription.rawValue {
                    let info = try JSONCoding.decode(SubscriptionInfo.self, from: row["info_json"])
                    subscriptions[info.ascId] = info
                } else {
                    let info = try JSONCoding.decode(IAPInfo.self, from: row["info_json"])
                    iaps[info.ascId] = info
                }
            }

            var groups: [String: SubscriptionGroupInfo] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT asc_id, reference_name FROM subscription_group WHERE last_sync >= ?", arguments: [syncId]) {
                let group = SubscriptionGroupInfo(ascId: row["asc_id"], referenceName: row["reference_name"])
                groups[group.ascId] = group
            }

            var territories: [TerritoryCode: CurrencyCode] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT code, currency FROM territory") {
                territories[TerritoryCode(row["code"] as String)] = CurrencyCode(row["currency"] as String)
            }

            var regular: [RegularPriceRow] = []
            var intro: [IntroOfferRow] = []
            var promo: [PromoOffer] = []
            var schedules: [String: IAPSchedule] = [:]
            var texts: [LocalizationRow] = []
            for observation in try Self.liveObservations(db, productAscId: nil) {
                switch observation.kind {
                case ObservationKind.price: regular.append(try JSONCoding.decode(RegularPriceRow.self, from: observation.rawJSON))
                case ObservationKind.intro: intro.append(try JSONCoding.decode(IntroOfferRow.self, from: observation.rawJSON))
                case ObservationKind.promo: promo.append(try JSONCoding.decode(PromoOffer.self, from: observation.rawJSON))
                case ObservationKind.iapSchedule:
                    let schedule = try JSONCoding.decode(IAPSchedule.self, from: observation.rawJSON)
                    schedules[schedule.iapId] = schedule
                case ObservationKind.localization: texts.append(try JSONCoding.decode(LocalizationRow.self, from: observation.rawJSON))
                default: continue
                }
            }

            let points = try pricePoints.index(db)
            let codes = Set(try String.fetchAll(db, sql: "SELECT offer_code FROM offer_code_registry"))
            let metadata = try Self.metadata(db, texts: texts, known: Set(subscriptions.keys.map { LocalizationOwner.subscription($0) }
                                                                         + iaps.keys.map { LocalizationOwner.iap($0) }
                                                                         + groups.keys.map { LocalizationOwner.group($0) }))

            return CatalogSnapshot(syncId: syncId, takenAt: takenAt, subscriptions: subscriptions, iaps: iaps, territories: territories,
                                   regularRows: regular, introRows: intro, promoOffers: promo, iapSchedules: schedules,
                                   pricePoints: points, offerCodesEverSeen: codes, groups: groups, metadata: metadata)
        }
    }

    /// Every version of the cell, oldest first.
    public func history(cell: CellKey) throws -> [ObservationRecord] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM observation WHERE cell_key = ? ORDER BY first_sync, id", arguments: [cell.storageKey])
                .map(Self.observation(from:))
        }
    }

    /// The rows currently shown for one product (latest complete read of each kind); used for provenance in the UI.
    public func liveObservations(productAscId: String) throws -> [ObservationRecord] {
        try database.writer.read { db in try Self.liveObservations(db, productAscId: productAscId) }
    }

    public func findings(includeAcked: Bool) throws -> [FindingRecord] {
        try database.writer.read { db in
            let sql = "SELECT * FROM finding" + (includeAcked ? "" : " WHERE ack_at IS NULL") + " ORDER BY id"
            return try Row.fetchAll(db, sql: sql).map(Self.finding(from:))
        }
    }

    /// Inserts a new finding and returns it, or bumps last_sync of the identical finding and returns nil.
    /// fingerprint = sha256hex("<type>|<rule or empty>|<cell storage key>|<message>"), plus "|<discriminator>" when one is
    /// given. SyncEngine's findings of one outside change pass what tells it from the next change of the same row (the new
    /// content hash, or the id of the observation that disappeared), so a change after an ack is a new finding.
    @discardableResult
    public func upsertFinding(type: FindingType, rule: RuleID?, cell: CellKey, message: String, discriminator: String? = nil,
                              syncId: Int64, in db: Database) throws -> FindingRecord? {
        let fingerprint = Self.fingerprint(type: type, rule: rule, cell: cell, message: message, discriminator: discriminator)
        if let existing = try Int64.fetchOne(db, sql: "SELECT id FROM finding WHERE fingerprint = ?", arguments: [fingerprint]) {
            try db.execute(sql: "UPDATE finding SET last_sync = ? WHERE id = ?", arguments: [syncId, existing])
            return nil
        }
        try db.execute(
            sql: "INSERT INTO finding (type, rule, cell_key, fingerprint, message, first_sync, last_sync) VALUES (?, ?, ?, ?, ?, ?, ?)",
            arguments: [type.rawValue, rule?.rawValue, cell.storageKey, fingerprint, message, syncId, syncId])
        return FindingRecord(id: db.lastInsertedRowID, type: type, rule: rule, cell: cell, fingerprint: fingerprint, message: message,
                             firstSync: syncId, lastSync: syncId, planId: nil, ackReason: nil, ackAt: nil)
    }

    public func ack(findingId: Int64, reason: String, at: Date) throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE finding SET ack_reason = ?, ack_at = ? WHERE id = ?",
                           arguments: [reason, Timestamp.string(at), findingId])
        }
    }

    // MARK: - Shared queries

    /// The stored versions (metadata_version) and the live LOCALIZATION observations of every owner still in the catalog.
    static func metadata(_ db: Database, texts: [LocalizationRow], known: Set<LocalizationOwner>) throws -> [LocalizationOwner: OwnerMetadata] {
        var versions: [LocalizationOwner: [MetadataVersion]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT asc_id, owner_key, number, state FROM metadata_version") {
            let key: String = row["owner_key"]
            guard let owner = LocalizationOwner(key: key) else {
                throw StoreError.corruptValue(table: "metadata_version", column: "owner_key", value: key)
            }
            versions[owner, default: []].append(MetadataVersion(ascId: row["asc_id"], owner: owner, number: row["number"],
                                                                state: MetadataVersionState(row["state"] as String)))
        }
        let textsByOwner = Dictionary(grouping: texts, by: \.owner)
        var result: [LocalizationOwner: OwnerMetadata] = [:]
        for owner in Set(versions.keys).union(textsByOwner.keys) where known.contains(owner) {
            result[owner] = OwnerMetadata(owner: owner, versions: versions[owner] ?? [], localizations: textsByOwner[owner] ?? [])
        }
        return result
    }

    static func fingerprint(type: FindingType, rule: RuleID?, cell: CellKey, message: String, discriminator: String? = nil) -> String {
        let parts = [type.rawValue, rule?.rawValue ?? "", cell.storageKey, message] + (discriminator.map { [$0] } ?? [])
        let input = parts.joined(separator: "|")
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// For each (product, kind) scope: the latest non-failed sync that read it completely.
    static func latestCompleteSyncPerScope(_ db: Database, before syncId: Int64? = nil) throws -> [String: Int64] {
        var result: [String: Int64] = [:]
        var sql = "SELECT id, complete_scopes_json FROM sync_run WHERE status IN ('complete', 'partial')"
        var arguments: StatementArguments = []
        if let syncId {
            sql += " AND id < ?"
            arguments = [syncId]
        }
        for row in try Row.fetchAll(db, sql: sql + " ORDER BY id", arguments: arguments) {
            let id: Int64 = row["id"]
            for scope in try JSONCoding.decode([String].self, from: row["complete_scopes_json"]) {
                result[scope] = id
            }
        }
        return result
    }

    static func liveObservations(_ db: Database, productAscId: String?) throws -> [ObservationRecord] {
        var result: [ObservationRecord] = []
        for (scope, syncId) in try latestCompleteSyncPerScope(db).sorted(by: { $0.key < $1.key }) {
            let parts = scope.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if let productAscId, parts[0] != productAscId { continue }
            result += try Row.fetchAll(db, sql: """
                SELECT * FROM observation WHERE product_asc_id = ? AND kind = ? AND last_sync = ? ORDER BY id
                """, arguments: [parts[0], parts[1], syncId]).map(observation(from:))
        }
        return result
    }

    static func observation(from row: Row) throws -> ObservationRecord {
        let key: String = row["cell_key"]
        guard let cell = CellKey(storageKey: key) else { throw StoreError.corruptValue(table: "observation", column: "cell_key", value: key) }
        let provenance: String = row["provenance"]
        guard let value = Provenance(rawValue: provenance) else {
            throw StoreError.corruptValue(table: "observation", column: "provenance", value: provenance)
        }
        return ObservationRecord(id: row["id"], kind: row["kind"], ascId: row["asc_id"], cell: cell, rawJSON: row["raw_json"],
                                 firstSync: row["first_sync"], lastSync: row["last_sync"], provenance: value,
                                 expired: (row["expired"] as Int) != 0)
    }

    static func finding(from row: Row) throws -> FindingRecord {
        let key: String = row["cell_key"]
        guard let cell = CellKey(storageKey: key) else { throw StoreError.corruptValue(table: "finding", column: "cell_key", value: key) }
        let type: String = row["type"]
        guard let findingType = FindingType(rawValue: type) else { throw StoreError.corruptValue(table: "finding", column: "type", value: type) }
        return FindingRecord(id: row["id"], type: findingType, rule: (row["rule"] as String?).map { RuleID($0) }, cell: cell,
                             fingerprint: row["fingerprint"], message: row["message"], firstSync: row["first_sync"],
                             lastSync: row["last_sync"], planId: row["plan_id"], ackReason: row["ack_reason"],
                             ackAt: try (row["ack_at"] as String?).map(Timestamp.date))
    }
}
