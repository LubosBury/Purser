import Foundation
import Synchronization
import Domain
import Audit
import PurserSecurity
import ASCClient

// Product creation (v1 scope change, 2026-10-11): Purser creates subscription groups, auto-renewable subscriptions and
// non-consumable in-app purchases, with availability in every territory. Prices and offers stay with plans.
// A product id can never be reused in the account, not even after the product is deleted.

public struct NewSubscriptionProduct: Hashable, Sendable, Codable {
    public var productId: String
    public var name: String              // reference name in ASC
    public var period: SubscriptionPeriod
    public init(productId: String, name: String, period: SubscriptionPeriod) {
        self.productId = productId; self.name = name; self.period = period
    }
}

public struct NewNonConsumableProduct: Hashable, Sendable, Codable {
    public var productId: String
    public var name: String
    public init(productId: String, name: String) {
        self.productId = productId; self.name = name
    }
}

public struct ProductCreationRequest: Hashable, Sendable, Codable {
    /// Reference name of the group the subscriptions go to; created when the app has no group of that name.
    public var groupName: String?
    public var subscriptions: [NewSubscriptionProduct]
    public var nonConsumables: [NewNonConsumableProduct]
    public init(groupName: String?, subscriptions: [NewSubscriptionProduct], nonConsumables: [NewNonConsumableProduct]) {
        self.groupName = groupName; self.subscriptions = subscriptions; self.nonConsumables = nonConsumables
    }

    /// The never-submitted test products every spike and first write runs on (spec D8).
    public static let purserSpike = ProductCreationRequest(
        groupName: "Purser Spike",
        subscriptions: [
            NewSubscriptionProduct(productId: "SpikeYearlyA", name: "SpikeYearlyA", period: .oneYear),
            NewSubscriptionProduct(productId: "SpikeYearlyB", name: "SpikeYearlyB", period: .oneYear),
            NewSubscriptionProduct(productId: "SpikeYearlyC", name: "SpikeYearlyC", period: .oneYear),
            NewSubscriptionProduct(productId: "SpikeMonthly", name: "SpikeMonthly", period: .oneMonth),
        ],
        nonConsumables: [NewNonConsumableProduct(productId: "PurserSpikeLifetime", name: "PurserSpikeLifetime")])
}

/// What the app already has, by the keys a request names: group reference name and product id -> ASC id.
public struct ExistingProducts: Hashable, Sendable {
    public var groups: [String: String] = [:]
    public var subscriptions: [String: String] = [:]
    public var nonConsumables: [String: String] = [:]
    public init() {}
}

public enum ProductCreationStep: Hashable, Sendable {
    case group(name: String)
    case subscription(NewSubscriptionProduct)
    case subscriptionAvailability(productId: String)
    case nonConsumable(NewNonConsumableProduct)
    case nonConsumableAvailability(productId: String)
}

public enum ProductCreationOutcome: Hashable, Sendable {
    case created(ascId: String)
    case failed(String)
    case skipped(String)
}

public struct ProductCreationReport: Hashable, Sendable {
    public var step: ProductCreationStep
    public var outcome: ProductCreationOutcome
}

public enum ProductCreationError: Error, Equatable, Sendable {
    case invalid([String])
    case bindingMismatch(String)
    /// Another creation or clone of the workspace is running (ProductRuns); nothing was read or sent.
    case anotherRunInProgress(ProductRunKind)
}

extension ProductCreationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalid(problems): return problems.joined(separator: " ")
        case let .bindingMismatch(detail): return "The workspace no longer matches the app in App Store Connect (\(detail))."
        case let .anotherRunInProgress(kind): return kind.waitMessage
        }
    }
}

/// What a ProductCreator run does: create new products, or clone existing ones.
public enum ProductRunKind: String, Sendable {
    case creation, clone

    /// What the owner (or Claude over MCP) is told while such a run is in progress.
    public var waitMessage: String {
        switch self {
        case .creation: return "New products are being created in Purser; wait until that finishes."
        case .clone: return "A clone is running in Purser; wait until it finishes."
        }
    }
}

/// One product creation or clone run per workspace at a time: a second run would read what the first is still writing and
/// could create the same products again. The session gives its one instance to every ProductCreator it builds, for the
/// windows and the MCP bridge alike; `create` and `clone` hold it from their first read to their last write. A clone's
/// price drafts (the sync and the plans built from the clones) are part of the run: its caller keeps a `ProductRunClaim`
/// over them.
public final class ProductRuns: Sendable {
    private let current = Mutex<ProductRunKind?>(nil)

    public init() {}

    /// The run in progress; nil when none is.
    public var running: ProductRunKind? { current.withLock { $0 } }

    func begin(_ kind: ProductRunKind) throws {
        try current.withLock { current throws(ProductCreationError) in
            if let other = current { throw .anotherRunInProgress(other) }
            current = kind
        }
    }

    func end() { current.withLock { $0 = nil } }

    /// Starts a run that its caller ends with `release`: `clone(_:snapshot:holding:)` takes such a claim, so the run stays
    /// marked while the caller goes on to the clone's drafts. Refused while another run is in progress.
    public func claim(_ kind: ProductRunKind) throws -> ProductRunClaim {
        try begin(kind)
        return ProductRunClaim(runs: self, kind: kind)
    }
}

/// A run of ProductRuns that its owner ends. It is released once: by `release`, or when the claim is dropped, so a path that
/// forgets it cannot block the workspace for good. A second `release` frees nothing, in particular not a later run.
public final class ProductRunClaim: Sendable {
    let runs: ProductRuns
    let kind: ProductRunKind
    private let held = Mutex(true)

    init(runs: ProductRuns, kind: ProductRunKind) {
        self.runs = runs
        self.kind = kind
    }

    deinit { release() }

    public func release() {
        let wasHeld = held.withLock { held in
            let was = held
            held = false
            return was
        }
        if wasHeld { runs.end() }
    }

    func holds(_ kind: ProductRunKind, in runs: ProductRuns) -> Bool {
        self.runs === runs && self.kind == kind && held.withLock { $0 }
    }
}

public enum ProductCreationPlanner {
    public static let maxProductIdLength = 100
    public static let maxNameLength = 64

    /// Czech messages for the form; empty when the request can be planned.
    public static func problems(_ request: ProductCreationRequest) -> [String] {
        if request.subscriptions.isEmpty && request.nonConsumables.isEmpty && (request.groupName ?? "").isEmpty {
            return ["There is nothing to create."]
        }
        var problems: [String] = []
        if !request.subscriptions.isEmpty && (request.groupName ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append("Subscriptions need a group name.")
        }
        let products = request.subscriptions.map { ($0.productId, $0.name) } + request.nonConsumables.map { ($0.productId, $0.name) }
        for (productId, name) in products {
            if productId.isEmpty || productId.count > maxProductIdLength
                || productId.unicodeScalars.contains(where: { !isAllowedInProductId($0) }) {
                problems.append("The Product ID “\(productId)” may contain only letters, digits, a period and an underscore (at most \(maxProductIdLength) characters).")
            }
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.count > maxNameLength {
                problems.append("The product “\(productId)” needs a name of 1 to \(maxNameLength) characters.")
            }
        }
        var seen: Set<String> = []
        for productId in products.map(\.0) where !seen.insert(productId).inserted {
            let message = "The Product ID “\(productId)” is in the list more than once."
            if !problems.contains(message) { problems.append(message) }
        }
        return problems
    }

    private static func isAllowedInProductId(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", ".", "_": return true
        default: return false
        }
    }

    /// The writes still needed, in order: group, then each subscription with its availability, then each non-consumable
    /// with its availability. A product that exists is left alone (its availability included).
    public static func steps(_ request: ProductCreationRequest, existing: ExistingProducts) -> [ProductCreationStep] {
        var steps: [ProductCreationStep] = []
        if let group = request.groupName, !group.isEmpty, existing.groups[group] == nil { steps.append(.group(name: group)) }
        for subscription in request.subscriptions where existing.subscriptions[subscription.productId] == nil {
            steps.append(.subscription(subscription))
            steps.append(.subscriptionAvailability(productId: subscription.productId))
        }
        for product in request.nonConsumables where existing.nonConsumables[product.productId] == nil {
            steps.append(.nonConsumable(product))
            steps.append(.nonConsumableAvailability(productId: product.productId))
        }
        return steps
    }
}

struct ProductSentPayload: Encodable, Sendable {
    var method: String
    var path: String
    var body: String
    /// Spec §5: key id and the token's jti, never the token.
    var keyId: String
    var jti: String
}

struct ProductReceivedPayload: Encodable, Sendable {
    var method: String
    var path: String
    var status: Int?
    var ascId: String?
    var error: String?

    enum CodingKeys: String, CodingKey { case method, path, status, ascId, error }

    /// K3: `status` is always present (null when no HTTP status came back).
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(method, forKey: .method)
        try container.encode(path, forKey: .path)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(ascId, forKey: .ascId)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

/// The single path that creates products in ASC. Like the Executor it lives in Sources/Executor, checks the live app
/// binding (A1), asks for Touch ID once per run, commits HTTP_SENT before and HTTP_RECEIVED after every request and
/// never retries. AppGuard lets a create through only under the workspace app. Running it again is safe: what exists
/// is skipped. Clones (ProductCreator+Clone.swift) take the same path; their review screenshots also use `assets`.
public actor ProductCreator {
    let config: WorkspaceConfig
    let http: ASCHTTPClient
    let reader: any ASCReading
    let audit: AuditLog
    let budget: RateBudget
    let gate: any BiometricGate
    /// Shared by every creator of the workspace: one `create` or `clone` at a time.
    let runs: ProductRuns
    /// Downloads and uploads the review screenshots of a clone; nil = the run cannot copy images.
    let assets: AssetTransfer?

    public init(config: WorkspaceConfig, http: ASCHTTPClient, reader: any ASCReading, audit: AuditLog, budget: RateBudget,
                gate: any BiometricGate, runs: ProductRuns, assets: AssetTransfer? = nil) {
        self.config = config; self.http = http; self.reader = reader; self.audit = audit; self.budget = budget; self.gate = gate
        self.runs = runs; self.assets = assets
    }

    /// Groups, subscriptions and non-consumables the app has now (read from ASC, not from the local catalog).
    public func existing() async throws -> ExistingProducts {
        var existing = ExistingProducts()
        for group in try await reader.subscriptionGroups(appId: config.appId) {
            existing.groups[group.referenceName] = group.id
            for subscription in try await reader.subscriptions(group: group) {
                existing.subscriptions[subscription.productId] = subscription.ascId
            }
        }
        for iap in try await reader.inAppPurchases(appId: config.appId) {
            existing.nonConsumables[iap.productId] = iap.ascId
        }
        return existing
    }

    /// Creates what the request names and the app does not have yet. Refused, before anything is read, while another
    /// creation or clone of the workspace runs (ProductRuns).
    public func create(_ request: ProductCreationRequest) async throws -> [ProductCreationReport] {
        try runs.begin(.creation)
        defer { runs.end() }
        let problems = ProductCreationPlanner.problems(request)
        guard problems.isEmpty else { throw ProductCreationError.invalid(problems) }
        try await checkBinding()
        let existing = try await existing()
        let steps = ProductCreationPlanner.steps(request, existing: existing)
        guard !steps.isEmpty else { return [] }
        let territories = try await reader.territories().map(\.id.rawValue).sorted()
        // Groups read under the workspace app just now may take new subscriptions.
        await http.appGuard.allowChildren(Set(existing.groups.values))
        try await gate.authenticate(reason: "create \(steps.count) items in App Store Connect (a Product ID can never be used again)")

        var groupId = request.groupName.flatMap { existing.groups[$0] }
        var productIds: [String: String] = [:]
        var reports: [ProductCreationReport] = []
        var stopReason: String?
        for step in steps {
            if let stopReason {
                reports.append(ProductCreationReport(step: step, outcome: .skipped(stopReason)))
                continue
            }
            let body: [String: Any]
            let path: String
            switch step {
            case let .group(name):
                path = "/v1/subscriptionGroups"
                body = Self.resource("subscriptionGroups", attributes: ["referenceName": name],
                                     relationships: ["app": Self.toOne("apps", config.appId)])
            case let .subscription(subscription):
                guard let groupId else {
                    reports.append(ProductCreationReport(step: step, outcome: .skipped("the group was not created")))
                    continue
                }
                path = "/v1/subscriptions"
                body = Self.resource("subscriptions",
                                     attributes: ["name": subscription.name, "productId": subscription.productId,
                                                  "subscriptionPeriod": subscription.period.rawValue],
                                     relationships: ["group": Self.toOne("subscriptionGroups", groupId)])
            case let .subscriptionAvailability(productId):
                guard let ascId = productIds[productId] else {
                    reports.append(ProductCreationReport(step: step, outcome: .skipped("the subscription was not created")))
                    continue
                }
                path = "/v1/subscriptionAvailabilities"
                body = Self.resource("subscriptionAvailabilities", attributes: ["availableInNewTerritories": true],
                                     relationships: ["subscription": Self.toOne("subscriptions", ascId),
                                                     "availableTerritories": Self.toMany("territories", territories)])
            case let .nonConsumable(product):
                path = "/v2/inAppPurchases"
                body = Self.resource("inAppPurchases",
                                     attributes: ["name": product.name, "productId": product.productId,
                                                  "inAppPurchaseType": "NON_CONSUMABLE"],
                                     relationships: ["app": Self.toOne("apps", config.appId)])
            case let .nonConsumableAvailability(productId):
                guard let ascId = productIds[productId] else {
                    reports.append(ProductCreationReport(step: step, outcome: .skipped("the purchase was not created")))
                    continue
                }
                path = "/v1/inAppPurchaseAvailabilities"
                body = Self.resource("inAppPurchaseAvailabilities", attributes: ["availableInNewTerritories": true],
                                     relationships: ["inAppPurchase": Self.toOne("inAppPurchases", ascId),
                                                     "availableTerritories": Self.toMany("territories", territories)])
            }
            do {
                let ascId = try await createResource(path: path, body: body, refs: Self.refs(step))
                reports.append(ProductCreationReport(step: step, outcome: .created(ascId: ascId)))
                switch step {
                case .group:
                    groupId = ascId
                    await http.appGuard.allowChildren([ascId])
                case let .subscription(subscription):
                    productIds[subscription.productId] = ascId
                    await http.appGuard.allowProducts([ascId])
                case let .nonConsumable(product):
                    productIds[product.productId] = ascId
                    await http.appGuard.allowProducts([ascId])
                case .subscriptionAvailability, .nonConsumableAvailability:
                    break
                }
            } catch let error as ASCError {
                reports.append(ProductCreationReport(step: step, outcome: .failed(Self.describe(error))))
                switch error {
                case .network(_, maybeSent: true):
                    stopReason = "the previous request may have reached Apple; run a sync and start the creation again"
                case .rateLimited:
                    stopReason = "the hourly request budget is used up; try again later"
                case .readOnlyClient:
                    stopReason = "read-only client"
                default:
                    break   // products that depend on this step are skipped by the missing id
                }
            }
        }
        return reports
    }

    /// Rule A1 against the live app: its id and bundle id are the workspace's.
    func checkBinding() async throws {
        let app = try await reader.app(id: config.appId)
        guard app.id == config.appId, app.bundleId == config.bundleId else {
            throw ProductCreationError.bindingMismatch("\(app.id) \(app.bundleId)")
        }
    }

    /// A POST that creates one resource; returns its id.
    func createResource(path: String, body: [String: Any], refs: [String: String]) async throws -> String {
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        guard let id = try await send(method: "POST", path: path, body: data, refs: refs, expectsId: true)?.data.first?.id else {
            throw ASCError.decoding("\(path): the response has no resource id")
        }
        return id
    }

    /// HTTP_SENT (committed) -> request -> HTTP_RECEIVED. Returns the response document (nil for an empty answer such as
    /// the 204 of a DELETE). With `expectsId`, an answer without a resource id is an error and is recorded as one.
    func send(method: String, path: String, body: Data?, refs: [String: String], expectsId: Bool) async throws -> JSONAPIDocument? {
        try await budget.acquire(forVerify: false)
        let tokenId = UUID().uuidString
        try audit.append(.httpSent, refs: refs, payload: ProductSentPayload(
            method: method, path: path, body: body.map { String(decoding: $0, as: UTF8.self) } ?? "", keyId: config.keyId, jti: tokenId))
        let http = self.http
        do {
            let document = try await ASCRequestContext.$tokenId.withValue(tokenId) { () async throws -> JSONAPIDocument? in
                if method == "DELETE" {
                    try await http.delete(path: path)
                    return nil
                }
                return try await http.send(method: method, path: path, body: body ?? Data())
            }
            let ascId = document?.data.first?.id
            if expectsId, ascId == nil { throw ASCError.decoding("\(path): the response has no resource id") }
            try audit.append(.httpReceived, refs: refs, payload: ProductReceivedPayload(
                method: method, path: path, status: Self.successStatus(method), ascId: ascId, error: nil))
            return document
        } catch let error as ASCError {
            var status: Int?
            if case let .http(code, _, _, _) = error { status = code }
            try audit.append(.httpReceived, refs: refs, payload: ProductReceivedPayload(
                method: method, path: path, status: status, ascId: nil, error: String(describing: error)))
            throw error
        }
    }

    /// The status of a successful answer (ASCHTTPClient does not pass it on): 201 for a POST, 204 for a DELETE, else 200.
    static func successStatus(_ method: String) -> Int {
        switch method {
        case "POST": return 201
        case "DELETE": return 204
        default: return 200
        }
    }

    static func refs(_ step: ProductCreationStep) -> [String: String] {
        switch step {
        case let .group(name): return ["create": "group", "product": name]
        case let .subscription(subscription): return ["create": "subscription", "product": subscription.productId]
        case let .subscriptionAvailability(productId): return ["create": "subscriptionAvailability", "product": productId]
        case let .nonConsumable(product): return ["create": "nonConsumable", "product": product.productId]
        case let .nonConsumableAvailability(productId): return ["create": "nonConsumableAvailability", "product": productId]
        }
    }

    static func describe(_ error: ASCError) -> String {
        switch error {
        case let .http(status, code, title, detail):
            return (["HTTP \(status)"] + [code, title, detail].compactMap { $0 }).joined(separator: " · ")
        default:
            return String(describing: error)
        }
    }

    static func resource(_ type: String, attributes: [String: Any], relationships: [String: Any]) -> [String: Any] {
        ["data": ["type": type, "attributes": attributes, "relationships": relationships]]
    }

    static func toOne(_ type: String, _ id: String) -> [String: Any] {
        ["data": ["type": type, "id": id]]
    }

    static func toMany(_ type: String, _ ids: [String]) -> [String: Any] {
        ["data": ids.map { ["type": type, "id": $0] }]
    }
}
