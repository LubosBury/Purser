import Foundation

/// Rule A9: refuses requests for resources outside the workspace app.
/// Products (subscriptions, IAPs) and their children become allowed only after they were read under the app.
public actor AppGuard {
    private let appId: String
    private var products: Set<String> = []
    private var children: Set<String> = []

    /// Resource collections whose ids must have been learned as children of an allowed product or group.
    static let childCollections: Set<String> = [
        "subscriptionGroups", "subscriptionAvailabilities", "subscriptionPlanAvailabilities",
        "subscriptionPrices", "subscriptionIntroductoryOffers", "subscriptionPromotionalOffers",
        "inAppPurchasePriceSchedules", "inAppPurchaseAvailabilities",
    ]
    static let productCollections: Set<String> = ["subscriptions", "inAppPurchases"]

    /// What a create request (POST without an id) must name to stay inside the workspace app.
    enum CreationParent { case workspaceApp, knownGroup }
    /// Collections whose resources Purser creates: groups and non-consumables under the app, subscriptions in a known group.
    static let creationParents: [String: CreationParent] = [
        "subscriptionGroups": .workspaceApp, "inAppPurchases": .workspaceApp, "subscriptions": .knownGroup,
    ]

    public init(appId: String) {
        self.appId = appId
    }

    public func allowProducts(_ ascIds: Set<String>) {
        products.formUnion(ascIds)
    }

    public func allowChildren(_ ascIds: Set<String>) {
        children.formUnion(ascIds)
    }

    public func check(method: String, path: String, body: Data?) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // "/v1/apps/123/x" -> ["", "v1", "apps", "123", "x"]
        guard parts.count >= 3, parts[0].isEmpty, ["v1", "v2"].contains(parts[1]),
              !parts.dropFirst().contains(where: { $0.isEmpty || $0 == ".." || $0 == "." }) else {
            throw ASCError.foreignResource(path)
        }
        let collection = parts[2]
        let id = parts.count > 3 ? parts[3] : nil
        if id == nil, method == "POST", let parent = Self.creationParents[collection] {
            guard let body, try bodyNamesAllowedParent(body, parent) else { throw ASCError.foreignResource(path) }
            return
        }
        switch collection {
        case "territories":
            guard method == "GET" else { throw ASCError.foreignResource(path) }
        case "subscriptionPricePoints":
            // Only the equalizations of a price point that belongs to an allowed subscription, read-only.
            guard method == "GET", parts.count == 5, parts[4] == "equalizations", let id,
                  let subscription = Self.subscriptionId(ofPricePoint: id), products.contains(subscription) else {
                throw ASCError.foreignResource(path)
            }
        case "apps":
            guard id == appId else { throw ASCError.foreignResource(path) }
        case _ where Self.productCollections.contains(collection):
            guard let id, products.contains(id) else { throw ASCError.foreignResource(path) }
        case _ where Self.childCollections.contains(collection):
            if let id {
                guard children.contains(id) else { throw ASCError.foreignResource(path) }
            } else {
                guard method == "POST", let body, try bodyReferencesOnlyAllowedProducts(body) else {
                    throw ASCError.foreignResource(path)
                }
            }
        default:
            throw ASCError.foreignResource(path)
        }
    }

    /// A subscription price point id is base64url JSON {"s": subscription, "t": territory, "p": tier}.
    /// nil for anything else, so an id in another format is refused, never guessed.
    static func subscriptionId(ofPricePoint id: String) -> String? {
        var base64 = id.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["s"] as? String
    }

    /// The body's `app` relationship must be the workspace app, or its `group` relationship a group read under it.
    private func bodyNamesAllowedParent(_ body: Data, _ parent: CreationParent) throws -> Bool {
        guard let root = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let data = root["data"] as? [String: Any],
              let relationships = data["relationships"] as? [String: Any] else { return false }
        func target(_ name: String, type: String) -> String? {
            guard let relationship = relationships[name] as? [String: Any], let target = relationship["data"] as? [String: Any],
                  target["type"] as? String == type else { return nil }
            return target["id"] as? String
        }
        switch parent {
        case .workspaceApp: return target("app", type: "apps") == appId
        case .knownGroup: return target("group", type: "subscriptionGroups").map(children.contains) ?? false
        }
    }

    /// A create request must name at least one product relationship, and every product it names must be allowed.
    private func bodyReferencesOnlyAllowedProducts(_ body: Data) throws -> Bool {
        guard let root = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let data = root["data"] as? [String: Any],
              let relationships = data["relationships"] as? [String: Any] else { return false }
        var referenced: [String] = []
        for case let relationship as [String: Any] in relationships.values {
            // JSON:API: `data` is one resource identifier (to-one) or an array of them (to-many).
            let targets: [[String: Any]]
            if let one = relationship["data"] as? [String: Any] {
                targets = [one]
            } else {
                targets = relationship["data"] as? [[String: Any]] ?? []
            }
            for target in targets {
                guard let type = target["type"] as? String, let id = target["id"] as? String else { continue }
                if Self.productCollections.contains(type) { referenced.append(id) }
            }
        }
        return !referenced.isEmpty && referenced.allSatisfy { products.contains($0) }
    }
}
