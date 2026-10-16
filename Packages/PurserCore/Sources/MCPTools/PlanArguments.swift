import Foundation
import Domain
import Catalog
import Planner
import Importer
import Executor
import MCPBridge

/// A tool argument that is missing or wrong; the message goes back to the model as the tool's error text.
public struct ToolArgumentError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Reads the arguments of the plan and product tools into the specs the Planner and the ProductCreator take.
/// Products may be named by ASC id or by Product ID; territories must exist in the snapshot.
public struct PlanArguments: Sendable {
    public let arguments: JSONValue
    public let snapshot: CatalogSnapshot

    public init(_ arguments: JSONValue, snapshot: CatalogSnapshot) {
        self.arguments = arguments; self.snapshot = snapshot
    }

    public var reason: String? {
        let text = arguments["reason"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    // MARK: Specs

    public func regular() throws -> PlanSpec {
        let ids = try strings("subscription_ids").map(subscription)
        guard !ids.isEmpty else { throw ToolArgumentError("subscription_ids is empty.") }
        return .regular(RegularPlanSpec(subscriptionIds: ids.sorted(), planType: .upfront, prices: try amounts("prices"),
                                        startDate: try date("start_date"), preserveCurrentPrice: arguments["preserve_current_price"]?.boolValue,
                                        skipIntroReplacement: [:], filter: PlanFilter(productAscIds: nil, territories: try territoryFilter())))
    }

    public func iap() throws -> PlanSpec {
        let base = try territory(try string("base_territory"))
        return .iap(IAPPlanSpec(iapId: try iap(try string("iap")), baseTerritory: base, prices: try amounts("prices"),
                                startDate: try date("start_date")))
    }

    public func intro() throws -> PlanSpec {
        let ids = try strings("subscription_ids").map(subscription)
        guard !ids.isEmpty else { throw ToolArgumentError("subscription_ids is empty.") }
        let mode: OfferMode = try choice("mode")
        return .intro(IntroPlanSpec(subscriptionIds: ids.sorted(), mode: mode, duration: try choice("duration"),
                                    numberOfPeriods: try periods(), pricing: try pricing(mode: mode),
                                    startDate: try date("start_date"), endDate: try date("end_date"),
                                    nominalDiscount: try percent("nominal_discount"),
                                    filter: PlanFilter(productAscIds: nil, territories: try territoryFilter()),
                                    canary: arguments["canary"]?.boolValue ?? false))
    }

    public func promo() throws -> PlanSpec {
        switch try string("action") {
        case "create":
            let mode: OfferMode = try choice("mode")
            return .promo(PromoPlanSpec(action: .create(subscriptionId: try subscription(try string("subscription")),
                                                        offerCode: try string("offer_code"), name: try string("name"), mode: mode,
                                                        duration: try choice("duration"), numberOfPeriods: try periods(),
                                                        pricing: try pricing(mode: mode))))
        case "reprice":
            let offer = try promoOffer(try string("offer_id"))
            return .promo(PromoPlanSpec(action: .reprice(offerAscId: offer.ascId, pricing: try pricing(mode: offer.mode))))
        case "delete":
            let offer = try promoOffer(try string("offer_id"))
            return .promo(PromoPlanSpec(action: .delete(offerAscId: offer.ascId,
                                                        confirmedUnusedByApp: arguments["confirmed_unused_by_app"]?.boolValue ?? false)))
        case let other:
            throw ToolArgumentError("action must be create, reprice or delete, not “\(other)”.")
        }
    }

    /// The spec of create_import_plan for a table the Importer already read with `mapping`.
    public func importTable(_ table: ImportedTable, mapping: ImportMapping) throws -> PlanSpec {
        let writable = Set(mapping.targets.filter(\.writes).map { $0.column.uppercased() })
        var columns = writable
        if let requested = arguments["write_columns"]?.arrayValue, !requested.isEmpty {
            columns = Set(try requested.map { value -> String in
                guard let column = value.stringValue?.trimmingCharacters(in: .whitespaces).uppercased(), writable.contains(column) else {
                    throw ToolArgumentError("write_columns may name only the written columns of the mapping: \(writable.sorted().joined(separator: ", ")).")
                }
                return column
            })
        }
        guard !columns.isEmpty else { throw ToolArgumentError("The import mapping has no column that is written.") }
        var products: Set<String>?
        if let references = arguments["products"]?.arrayValue, !references.isEmpty {
            products = Set(try references.map { value -> String in
                guard let reference = value.stringValue else { throw ToolArgumentError("“products” must contain only strings.") }
                if let id = try? subscription(reference) { return id }
                return try iap(reference)
            })
        }
        return .importTable(ImportPlanSpec(table: table, writeColumns: columns.sorted(),
                                           filter: PlanFilter(productAscIds: products, territories: try territoryFilter()),
                                           startDate: try date("start_date"), preserveCurrentPrice: arguments["preserve_current_price"]?.boolValue,
                                           canary: arguments["canary"]?.boolValue ?? false))
    }

    // MARK: Products

    /// The request of preview_new_products and create_products; needs no snapshot.
    public static func productCreation(_ arguments: JSONValue) throws -> ProductCreationRequest {
        func text(_ item: JSONValue, _ key: String) throws -> String {
            guard let value = item[key]?.stringValue else { throw ToolArgumentError("Every product needs “\(key)”.") }
            return value
        }
        let subscriptions = try (arguments["subscriptions"]?.arrayValue ?? []).map { item -> NewSubscriptionProduct in
            let raw = try text(item, "period")
            guard let period = SubscriptionPeriod(rawValue: raw) else {
                throw ToolArgumentError("period must be one of \(SubscriptionPeriod.allCases.map(\.rawValue).joined(separator: ", ")), not “\(raw)”.")
            }
            return NewSubscriptionProduct(productId: try text(item, "product_id"), name: try text(item, "name"), period: period)
        }
        let nonConsumables = try (arguments["non_consumables"]?.arrayValue ?? []).map {
            NewNonConsumableProduct(productId: try text($0, "product_id"), name: try text($0, "name"))
        }
        let group = arguments["group_name"]?.stringValue?.trimmingCharacters(in: .whitespaces)
        return ProductCreationRequest(groupName: (group ?? "").isEmpty ? nil : group, subscriptions: subscriptions, nonConsumables: nonConsumables)
    }

    // MARK: Lookup

    public func subscription(_ reference: String) throws -> String {
        if snapshot.subscriptions[reference] != nil { return reference }
        if let match = snapshot.subscriptions.values.first(where: { $0.productId == reference }) { return match.ascId }
        throw ToolArgumentError("No subscription with the ASC id or Product ID “\(reference)”. list_products shows the known ones.")
    }

    public func iap(_ reference: String) throws -> String {
        if snapshot.iaps[reference] != nil { return reference }
        if let match = snapshot.iaps.values.first(where: { $0.productId == reference }) { return match.ascId }
        throw ToolArgumentError("No in-app purchase with the ASC id or Product ID “\(reference)”. list_products shows the known ones.")
    }

    public func territory(_ code: String) throws -> TerritoryCode {
        let territory = TerritoryCode(code.trimmingCharacters(in: .whitespaces))
        guard snapshot.territories[territory] != nil else {
            throw ToolArgumentError("Unknown territory “\(code)”; use ISO 3166-1 alpha-3 codes such as USA or CZE.")
        }
        return territory
    }

    private func promoOffer(_ ascId: String) throws -> PromoOffer {
        guard let offer = snapshot.promoOffers.first(where: { $0.ascId == ascId }) else {
            throw ToolArgumentError("No promotional offer with the ASC id “\(ascId)”. get_prices lists the offers of a subscription.")
        }
        return offer
    }

    // MARK: Values

    public func string(_ key: String) throws -> String {
        guard let value = arguments[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw ToolArgumentError("“\(key)” is required.")
        }
        return value
    }

    public func strings(_ key: String) throws -> [String] {
        guard let values = arguments[key]?.arrayValue else { throw ToolArgumentError("“\(key)” is required (a list of strings).") }
        return try values.map {
            guard let text = $0.stringValue else { throw ToolArgumentError("“\(key)” must contain only strings.") }
            return text
        }
    }

    /// nil when the list is absent or empty (= every territory).
    public func territoryFilter() throws -> Set<TerritoryCode>? {
        guard let values = arguments["territories"]?.arrayValue, !values.isEmpty else { return nil }
        return Set(try values.map {
            guard let text = $0.stringValue else { throw ToolArgumentError("“territories” must contain only strings.") }
            return try territory(text)
        })
    }

    private func date(_ key: String) throws -> CalendarDate? {
        guard let text = arguments[key]?.stringValue, !text.isEmpty else { return nil }
        guard let date = CalendarDate(iso: text) else { throw ToolArgumentError("“\(key)” must be a date as YYYY-MM-DD, not “\(text)”.") }
        return date
    }

    private func choice<Value: RawRepresentable & CaseIterable>(_ key: String) throws -> Value where Value.RawValue == String {
        let raw = try string(key)
        guard let value = Value(rawValue: raw) else {
            throw ToolArgumentError("“\(key)” must be one of \(Value.allCases.map(\.rawValue).joined(separator: ", ")), not “\(raw)”.")
        }
        return value
    }

    private func periods() throws -> Int {
        guard let count = arguments["number_of_periods"]?.intValue, count >= 1 else {
            throw ToolArgumentError("“number_of_periods” must be a whole number of at least 1.")
        }
        return count
    }

    /// A percentage argument (20 = 20%) as a fraction; nil when absent.
    private func percent(_ key: String) throws -> Decimal? {
        guard let value = arguments[key], !value.isNull else { return nil }
        guard let percent = Self.decimal(value), percent > 0, percent < 100 else {
            throw ToolArgumentError("“\(key)” must be a percentage between 0 and 100.")
        }
        return percent / 100
    }

    private func amounts(_ key: String) throws -> [TerritoryAmount] {
        guard let items = arguments[key]?.arrayValue, !items.isEmpty else {
            throw ToolArgumentError("“\(key)” is required: a list of {territory, amount}.")
        }
        var seen: Set<TerritoryCode> = []
        return try items.map { item in
            guard let code = item["territory"]?.stringValue, let raw = item["amount"], let amount = Self.decimal(raw) else {
                throw ToolArgumentError("Every entry of “\(key)” needs a territory and an amount.")
            }
            guard amount >= 0 else { throw ToolArgumentError("The amount for \(code) is negative.") }
            let territory = try territory(code)
            guard seen.insert(territory).inserted else { throw ToolArgumentError("\(territory) is in “\(key)” more than once.") }
            return TerritoryAmount(territory: territory, amount: amount)
        }
    }

    private func pricing(mode: OfferMode) throws -> IntroPricing {
        let hasPercent = !(arguments["percent_of_regular"]?.isNull ?? true)
        let hasPrices = !(arguments["prices"]?.arrayValue ?? []).isEmpty
        if mode == .freeTrial {
            guard !hasPercent, !hasPrices else { throw ToolArgumentError("A FREE_TRIAL offer has no price; leave out percent_of_regular and prices.") }
            return .freeTrial
        }
        switch (hasPercent, hasPrices) {
        case (true, false): return .percentOfRegular(try percent("percent_of_regular") ?? 0)
        case (false, true): return .table(try amounts("prices"))
        case (true, true): throw ToolArgumentError("Give percent_of_regular or prices, not both.")
        case (false, false): throw ToolArgumentError("A paid offer needs percent_of_regular or prices.")
        }
    }

    /// JSON numbers arrive as doubles; their shortest decimal text ("9.99") is the amount the caller wrote.
    static func decimal(_ value: JSONValue) -> Decimal? {
        switch value {
        case let .number(number) where number.isFinite: return Decimal(string: "\(number)", locale: Locale(identifier: "en_US_POSIX"))
        case let .string(text):
            // Decimal(string:) stops at the first character it cannot read ("9.99abc" -> 9.99), so check the shape first.
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard trimmed.wholeMatch(of: /[0-9]+(\.[0-9]+)?/) != nil else { return nil }
            return Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
        default: return nil
        }
    }
}
