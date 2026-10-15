#if DEBUG
import Foundation
import Domain
import Store
import Audit
import PurserSecurity
import ASCClient
import Catalog

/// One raw ASC request of a spike on the "Purser Spike" group (spec D8, §9).
public struct SpikeRequest: Hashable, Sendable, Codable {
    public var spikeId: String       // "S2" … "S10"; goes to refs["spike"]
    public var step: String          // e.g. "S7-A-2"; goes to refs["step"]
    public var method: String        // "GET", "POST", "PATCH" or "DELETE"
    public var path: String          // "/v1/…" or "/v2/…", without query
    public var query: String         // raw query without "?", "" when none
    public var body: Data?           // JSON body exactly as sent; nil for GET and DELETE
    public init(spikeId: String, step: String, method: String, path: String, query: String, body: Data?) {
        self.spikeId = spikeId; self.step = step; self.method = method; self.path = path; self.query = query; self.body = body
    }
}

public struct SpikeResponse: Hashable, Sendable {
    public var status: Int
    public var body: Data            // raw response body; headers are never kept
    /// Ids of the `data` and `included` resources of a 2xx response to POST; added to this probe's allowlist.
    public var createdIds: [String]
    public init(status: Int, body: Data, createdIds: [String]) {
        self.status = status; self.body = body; self.createdIds = createdIds
    }
}

public enum SpikeProbeError: Error, Equatable, Sendable {
    case productionWorkspace
    case anotherPlanApplying(String)
    case noSnapshot
    case methodNotAllowed(String)
    case invalidPath(String)
    case bindingMismatch(String)
    case idNotAllowed(String)
}

struct SpikeSentPayload: Encodable, Sendable {
    var method: String
    var path: String
    var query: String
    var body: String?
    /// Spec §5: key id and the token's jti, never the token.
    var keyId: String
    var jti: String
}

struct SpikeReceivedPayload: Encodable, Sendable {
    var method: String
    var path: String
    var status: Int?
    var body: String?
    var bodyBytes: Int?
    var error: String?

    enum CodingKeys: String, CodingKey { case method, path, status, body, bodyBytes, error }

    /// K3: `status` is always present (null after a transport error).
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(method, forKey: .method)
        try container.encode(path, forKey: .path)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(body, forKey: .body)
        try container.encodeIfPresent(bodyBytes, forKey: .bodyBytes)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

/// DEBUG only (K10): the single path for spike writes that cannot run as a plan. It lives in Sources/Executor, refuses
/// production workspaces, applying plans and every id outside the "Purser Spike" group, asks for Touch ID before each
/// write and writes HTTP_SENT (committed) before and HTTP_RECEIVED after every request. It never retries and never reads
/// or stores headers.
public actor SpikeProbe {
    public static let spikeGroupName = "Purser Spike"
    public static let spikeIAPProductId = "PurserSpikeLifetime"
    static let methods: Set<String> = ["GET", "POST", "PATCH", "DELETE"]

    let config: WorkspaceConfig
    let http: ASCHTTPClient
    let reader: any ASCReading
    let catalog: CatalogStore
    let plans: PlanStore
    let audit: AuditLog
    let budget: RateBudget
    let gate: any BiometricGate
    let now: @Sendable () -> Date
    private var created: Set<String> = []

    /// `http` must be a write-capable ASCHTTPClient sharing the session's AppGuard and RateBudget.
    public init(config: WorkspaceConfig, http: ASCHTTPClient, reader: any ASCReading, catalog: CatalogStore,
                plans: PlanStore, audit: AuditLog, budget: RateBudget, gate: any BiometricGate,
                now: @escaping @Sendable () -> Date) {
        self.config = config; self.http = http; self.reader = reader; self.catalog = catalog; self.plans = plans
        self.audit = audit; self.budget = budget; self.gate = gate; self.now = now
    }

    /// From the latest snapshot: the "Purser Spike" group, its subscriptions, their price points, regular price rows, intro
    /// rows, promo offers and promo prices; the IAP with productId `spikeIAPProductId`, its schedule, manual prices and price
    /// points; the versions and localizations of the spike subscriptions, the spike group and that IAP (spike SL10n); plus
    /// every id this probe instance created. Throws noSnapshot.
    public func allowedIds() throws -> Set<String> {
        guard let snapshot = try catalog.latestSnapshot() else { throw SpikeProbeError.noSnapshot }
        var ids = created
        let subscriptions = snapshot.subscriptions.values.filter { $0.groupName == Self.spikeGroupName }
        let subscriptionIds = Set(subscriptions.map(\.ascId))
        var owners = subscriptionIds.sorted().map { LocalizationOwner.subscription($0) }
            + Set(subscriptions.map(\.groupId)).sorted().map { LocalizationOwner.group($0) }
        for subscription in subscriptions {
            ids.insert(subscription.groupId)
            ids.insert(subscription.ascId)
            for territory in snapshot.territories.keys {
                for planType in [PlanType.upfront, .monthly] {
                    for point in snapshot.pricePoints.points(productAscId: subscription.ascId, territory: territory, planType: planType) {
                        ids.insert(point.id)
                    }
                }
            }
        }
        for row in snapshot.regularRows where subscriptionIds.contains(row.subscriptionId) {
            ids.insert(row.ascId)
            ids.insert(row.pricePointId)
        }
        for row in snapshot.introRows where subscriptionIds.contains(row.subscriptionId) {
            ids.insert(row.ascId)
            if let point = row.pricePointId { ids.insert(point) }
        }
        for offer in snapshot.promoOffers where subscriptionIds.contains(offer.subscriptionId) {
            ids.insert(offer.ascId)
            for price in offer.prices {
                if let id = price.ascId { ids.insert(id) }
                if let point = price.pricePointId { ids.insert(point) }
            }
        }
        if let iap = snapshot.iaps.values.first(where: { $0.productId == Self.spikeIAPProductId }) {
            ids.insert(iap.ascId)
            owners.append(.iap(iap.ascId))
            for territory in snapshot.territories.keys {
                for point in snapshot.pricePoints.points(productAscId: iap.ascId, territory: territory, planType: nil) { ids.insert(point.id) }
            }
            if let schedule = snapshot.iapSchedules[iap.ascId] {
                if let id = schedule.scheduleId { ids.insert(id) }
                for price in schedule.manualPrices {
                    if let id = price.ascId { ids.insert(id) }
                    ids.insert(price.pricePointId)
                }
            }
        }
        for owner in owners {
            guard let metadata = snapshot.metadata[owner] else { continue }
            ids.formUnion(metadata.versions.map(\.ascId))
            ids.formUnion(metadata.localizations.map(\.ascId))
        }
        return ids
    }

    /// K10 order: production -> applying plan -> method -> path -> live binding (A1) -> ids -> Touch ID and budget (writes)
    /// -> httpSent (own transaction) -> request -> httpReceived -> created ids join the allowlist.
    public func send(_ request: SpikeRequest) async throws -> SpikeResponse {
        guard !config.isProduction else { throw SpikeProbeError.productionWorkspace }
        if let applying = try plans.plans(states: [.applying]).first { throw SpikeProbeError.anotherPlanApplying(applying.id) }
        let method = request.method
        guard Self.methods.contains(method) else { throw SpikeProbeError.methodNotAllowed(method) }
        try Self.checkPath(request.path)
        let app = try await reader.app(id: config.appId)
        guard app.id == config.appId, app.bundleId == config.bundleId else {
            throw SpikeProbeError.bindingMismatch("\(app.id) \(app.bundleId)")
        }
        let allowed = try allowedIds()
        for id in try Self.ids(in: request) where !allowed.contains(id) && !(method == "GET" && id == config.appId) {
            throw SpikeProbeError.idNotAllowed(id)
        }
        let isWrite = method != "GET"
        let body = method == "POST" || method == "PATCH" ? request.body : nil
        if isWrite {
            try await gate.authenticate(reason: "Spike \(request.spikeId) \(request.step): \(method) \(request.path)")
            try await budget.acquire(forVerify: false)
        }
        let refs = ["spike": request.spikeId, "step": request.step]
        let tokenId = UUID().uuidString
        try audit.append(.httpSent, refs: refs, payload: SpikeSentPayload(
            method: method, path: request.path, query: request.query, body: body.map { String(decoding: $0, as: UTF8.self) },
            keyId: config.keyId, jti: tokenId))
        let http = self.http
        let path = request.path
        let query = request.query
        let result: (status: Int, body: Data)
        do {
            result = try await ASCRequestContext.$tokenId.withValue(tokenId) {
                try await http.sendRaw(method: method, path: path, query: query, body: body)
            }
        } catch let error as ASCError {
            try audit.append(.httpReceived, refs: refs, payload: SpikeReceivedPayload(
                method: method, path: path, status: nil, body: nil, bodyBytes: nil, error: String(describing: error)))
            throw error
        }
        try audit.append(.httpReceived, refs: refs, payload: SpikeReceivedPayload(
            method: method, path: path, status: result.status, body: isWrite ? String(decoding: result.body, as: UTF8.self) : nil,
            bodyBytes: isWrite ? nil : result.body.count, error: nil))
        var createdIds: [String] = []
        if method == "POST", (200..<300).contains(result.status) {
            createdIds = Self.resourceIds(in: result.body)
            created.formUnion(createdIds)
        }
        return SpikeResponse(status: result.status, body: result.body, createdIds: createdIds)
    }

    /// "/v1/…" or "/v2/…", no "?", no ".." and no empty segment.
    static func checkPath(_ path: String) throws {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard path.hasPrefix("/v1/") || path.hasPrefix("/v2/"), !path.contains("?"),
              segments.allSatisfy({ !$0.isEmpty && $0 != ".." }) else { throw SpikeProbeError.invalidPath(path) }
    }

    /// The path segment at position 2 ("/v1/<type>/<id>/…") and every string "id" in the body, except local ids "${…}"
    /// and identifiers of type "territories" (territory codes, also under baseTerritory).
    static func ids(in request: SpikeRequest) throws -> [String] {
        var ids: [String] = []
        let segments = request.path.split(separator: "/").map(String.init)
        if segments.count > 2 { ids.append(segments[2]) }
        if let body = request.body, !body.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: body) else { throw SpikeProbeError.idNotAllowed("<body is not JSON>") }
            collect(object, into: &ids)
        }
        return ids
    }

    static func collect(_ value: Any, into ids: inout [String]) {
        if let object = value as? [String: Any] {
            if let id = object["id"] as? String, !id.hasPrefix("${"), object["type"] as? String != "territories" { ids.append(id) }
            for (key, child) in object where key != "id" { collect(child, into: &ids) }
        } else if let array = value as? [Any] {
            for child in array { collect(child, into: &ids) }
        }
    }

    static func resourceIds(in data: Data) -> [String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        var resources: [[String: Any]] = []
        if let single = root["data"] as? [String: Any] { resources.append(single) }
        if let many = root["data"] as? [[String: Any]] { resources += many }
        resources += root["included"] as? [[String: Any]] ?? []
        return resources.compactMap { $0["id"] as? String }
    }
}
#endif
