import Foundation

/// Rule A9: refuses requests for resources outside the workspace app.
/// Products (subscriptions, IAPs) and their children become allowed only after they were read under the app.
public actor AppGuard {
    private let appId: String
    private var products: Set<String> = []
    private var children: Set<String> = []
    /// Review screenshots this guard lets be committed (PATCH) or deleted: the ids an admitted reservation (POST
    /// …AppStoreReviewScreenshots) returned, filled by ASCHTTPClient from the 2xx answer only, until a commit or a DELETE
    /// of the id succeeds. A screenshot learned any other way, such as the read of a source product's screenshot, and a
    /// finished one (a clone that is now the source of another clone) are read and never changed.
    private var reservedScreenshots: Set<String> = []

    /// Resource collections whose ids must have been learned as children of an allowed product or group.
    static let childCollections: Set<String> = [
        "subscriptionGroups", "subscriptionAvailabilities", "subscriptionPlanAvailabilities",
        "subscriptionPrices", "subscriptionIntroductoryOffers", "subscriptionPromotionalOffers",
        "inAppPurchasePriceSchedules", "inAppPurchaseAvailabilities",
    ]
    /// Child collections Purser never changes or deletes: by id they are only read. Some are created (a POST without an id).
    static let readOnlyByIdCollections: Set<String> = [
        "subscriptionGroups", "subscriptionAvailabilities", "subscriptionPlanAvailabilities",
        "inAppPurchasePriceSchedules", "inAppPurchaseAvailabilities",
    ]
    /// Products: created by a POST without an id (creationParents), otherwise only read, their sub-resources included.
    static let productCollections: Set<String> = ["subscriptions", "inAppPurchases"]
    /// Metadata versions (ASC API 4.4.1): only read, and only by an id learned under an allowed product or group.
    static let readOnlyChildCollections: Set<String> = ["subscriptionVersions", "inAppPurchaseVersions", "subscriptionGroupVersions"]
    /// v2 localization collections (L2) -> the version type their `version` relationship must name.
    static let localizationParents: [String: String] = [
        "subscriptionLocalizations": "subscriptionVersions",
        "inAppPurchaseLocalizations": "inAppPurchaseVersions",
        "subscriptionGroupLocalizations": "subscriptionGroupVersions",
    ]
    /// Version collections -> the relationship (and its type) a POST of a new version must name.
    static let versionParents: [String: (relationship: String, type: String)] = [
        "subscriptionVersions": ("subscription", "subscriptions"),
        "inAppPurchaseVersions": ("inAppPurchase", "inAppPurchases"),
        "subscriptionGroupVersions": ("subscriptionGroup", "subscriptionGroups"),
    ]

    /// Review screenshot collections -> the relationship (and its type) a reservation must name: the product it belongs to.
    /// By id a screenshot is read when it was learned, and committed or deleted only when this guard saw it reserved.
    static let screenshotParents: [String: (relationship: String, type: String)] = [
        "subscriptionAppStoreReviewScreenshots": ("subscription", "subscriptions"),
        "inAppPurchaseAppStoreReviewScreenshots": ("inAppPurchaseV2", "inAppPurchases"),
    ]

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

    /// Step 6 of ASCHTTPClient after every 2xx answer to a request this guard admitted, an empty one (204) included. A
    /// screenshot reservation makes the ids of its primary resources of the reservation's own type changeable
    /// (`reservedScreenshots`); a commit (PATCH) or a DELETE of such an id ends that. Internal to the module: nothing but
    /// the client that sent the request can name a screenshot as its own (ArchitectureTests).
    func learnAnswer(method: String, path: String, resources: [(type: String, id: String)]) {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[0].isEmpty, parts[1] == "v1", Self.screenshotParents[parts[2]] != nil else { return }
        switch (method, parts.count) {
        case ("POST", 3): reservedScreenshots.formUnion(resources.filter { $0.type == parts[2] }.map(\.id))
        case ("PATCH", 4), ("DELETE", 4): reservedScreenshots.remove(parts[3])
        default: break
        }
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
        if id == nil, method == "POST", let parent = Self.versionParents[collection] {
            // A new version only for an allowed product or a group read under the app (spike SL10n Q3, L3).
            // Reads of versions stay with readOnlyChildCollections; PATCH and DELETE of a version are never allowed.
            guard parts[1] == "v1", parts.count == 3, let body,
                  let owner = Self.relationshipTarget(body, parent.relationship, type: parent.type),
                  (Self.productCollections.contains(parent.type) ? products.contains(owner) : children.contains(owner)) else {
                throw ASCError.foreignResource(path)
            }
            return
        }
        if id == nil, method == "POST", let parent = Self.screenshotParents[collection] {
            // A review screenshot is reserved only for an allowed product, named through the relationship of its own
            // collection, and no other relationship may name a product that is not allowed. PATCH and DELETE of the
            // reservation need the id its answer returned (learnAnswer, reservedScreenshots).
            guard parts[1] == "v1", let body,
                  let product = Self.relationshipTarget(body, parent.relationship, type: parent.type), products.contains(product),
                  try bodyReferencesOnlyAllowedProducts(body) else {
                throw ASCError.foreignResource(path)
            }
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
        case _ where Self.localizationParents[collection] != nil:
            try checkLocalization(method: method, parts: parts, collection: collection, id: id, body: body, path: path)
        case _ where Self.productCollections.contains(collection):
            guard method == "GET", let id, products.contains(id) else { throw ASCError.foreignResource(path) }
        case _ where Self.screenshotParents[collection] != nil:
            // By id only, no sub-resource. GET of an id learned under an allowed product; PATCH (the commit, naming the same
            // screenshot) and DELETE only of a reservation this guard admitted, never of a screenshot it only read.
            guard parts[1] == "v1", parts.count == 4, let id, ["GET", "PATCH", "DELETE"].contains(method) else {
                throw ASCError.foreignResource(path)
            }
            if method == "GET" {
                guard children.contains(id) || reservedScreenshots.contains(id) else { throw ASCError.foreignResource(path) }
            } else {
                guard reservedScreenshots.contains(id) else { throw ASCError.foreignResource(path) }
            }
            if method == "PATCH" {
                guard let body, Self.bodyIdentifies(body, type: collection, id: id) else { throw ASCError.foreignResource(path) }
            }
        case _ where Self.readOnlyChildCollections.contains(collection):
            guard method == "GET", let id, children.contains(id) else { throw ASCError.foreignResource(path) }
        case _ where Self.childCollections.contains(collection):
            if let id {
                guard children.contains(id), method == "GET" || !Self.readOnlyByIdCollections.contains(collection) else {
                    throw ASCError.foreignResource(path)
                }
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

    /// Localizations (v2): POST only into a version read under an allowed owner; GET and PATCH only of an id learned from a read
    /// or returned by a POST, a PATCH body naming that id. No sub-resources, and never a DELETE (L-D4: no locale is removed).
    private func checkLocalization(method: String, parts: [String], collection: String, id: String?, body: Data?, path: String) throws {
        guard parts[1] == "v2", let versionType = Self.localizationParents[collection] else { throw ASCError.foreignResource(path) }
        guard let id else {
            guard method == "POST", parts.count == 3, let body,
                  let version = Self.relationshipTarget(body, "version", type: versionType), children.contains(version) else {
                throw ASCError.foreignResource(path)
            }
            return
        }
        guard parts.count == 4, ["GET", "PATCH"].contains(method), children.contains(id) else { throw ASCError.foreignResource(path) }
        if method == "PATCH" {
            guard let body, Self.bodyIdentifies(body, type: collection, id: id) else { throw ASCError.foreignResource(path) }
        }
    }

    /// The id of the to-one relationship `name` when it names a resource of `type`; nil for anything else (also invalid JSON).
    static func relationshipTarget(_ body: Data, _ name: String, type: String) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let data = root["data"] as? [String: Any],
              let relationships = data["relationships"] as? [String: Any],
              let relationship = relationships[name] as? [String: Any],
              let target = relationship["data"] as? [String: Any], target["type"] as? String == type else { return nil }
        return target["id"] as? String
    }

    /// The body's primary resource is `type` with `id`.
    static func bodyIdentifies(_ body: Data, type: String, id: String) -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let data = root["data"] as? [String: Any] else { return false }
        return data["type"] as? String == type && data["id"] as? String == id
    }
}
