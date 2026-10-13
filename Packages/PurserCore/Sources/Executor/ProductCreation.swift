import Foundation
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
/// is skipped.
public actor ProductCreator {
    private let config: WorkspaceConfig
    private let http: ASCHTTPClient
    private let reader: any ASCReading
    private let audit: AuditLog
    private let budget: RateBudget
    private let gate: any BiometricGate

    public init(config: WorkspaceConfig, http: ASCHTTPClient, reader: any ASCReading, audit: AuditLog, budget: RateBudget,
                gate: any BiometricGate) {
        self.config = config; self.http = http; self.reader = reader; self.audit = audit; self.budget = budget; self.gate = gate
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

    public func create(_ request: ProductCreationRequest) async throws -> [ProductCreationReport] {
        let problems = ProductCreationPlanner.problems(request)
        guard problems.isEmpty else { throw ProductCreationError.invalid(problems) }
        let app = try await reader.app(id: config.appId)
        guard app.id == config.appId, app.bundleId == config.bundleId else {
            throw ProductCreationError.bindingMismatch("\(app.id) \(app.bundleId)")
        }
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
                let ascId = try await post(path: path, body: body, step: step)
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

    /// HTTP_SENT (committed) -> request -> HTTP_RECEIVED. Returns the id of the created resource.
    private func post(path: String, body: [String: Any], step: ProductCreationStep) async throws -> String {
        try await budget.acquire(forVerify: false)
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let refs = Self.refs(step)
        let tokenId = UUID().uuidString
        try audit.append(.httpSent, refs: refs, payload: ProductSentPayload(
            method: "POST", path: path, body: String(decoding: data, as: UTF8.self), keyId: config.keyId, jti: tokenId))
        let http = self.http
        do {
            let document = try await ASCRequestContext.$tokenId.withValue(tokenId) {
                try await http.send(method: "POST", path: path, body: data)
            }
            guard let ascId = document?.data.first?.id else {
                throw ASCError.decoding("\(path): the response has no resource id")
            }
            try audit.append(.httpReceived, refs: refs, payload: ProductReceivedPayload(
                method: "POST", path: path, status: 201, ascId: ascId, error: nil))
            return ascId
        } catch let error as ASCError {
            var status: Int?
            if case let .http(code, _, _, _) = error { status = code }
            try audit.append(.httpReceived, refs: refs, payload: ProductReceivedPayload(
                method: "POST", path: path, status: status, ascId: nil, error: String(describing: error)))
            throw error
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

    private static func resource(_ type: String, attributes: [String: Any], relationships: [String: Any]) -> [String: Any] {
        ["data": ["type": type, "attributes": attributes, "relationships": relationships]]
    }

    private static func toOne(_ type: String, _ id: String) -> [String: Any] {
        ["data": ["type": type, "id": id]]
    }

    private static func toMany(_ type: String, _ ids: [String]) -> [String: Any] {
        ["data": ids.map { ["type": type, "id": $0] }]
    }
}
