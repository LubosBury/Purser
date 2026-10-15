import Foundation
import Domain

extension LiveASCClient {
    private static let limit200 = URLQueryItem(name: "limit", value: "200")
    private static let limit8000 = URLQueryItem(name: "limit", value: "8000")

    public func app(id: String) async throws -> ASCApp {
        try ASCMapping.app(try await http.get(ASCPath.app(id), query: []))
    }

    public func territories() async throws -> [ASCTerritory] {
        try ASCMapping.territories(try await http.getAll(ASCPath.territories, query: [Self.limit200]))
    }

    public func subscriptionGroups(appId: String) async throws -> [ASCSubscriptionGroup] {
        let groups = ASCMapping.groups(try await http.getAll(ASCPath.subscriptionGroups(app: appId), query: [Self.limit200]))
        await http.appGuard.allowChildren(Set(groups.map(\.id)))
        return groups
    }

    public func subscriptions(group: ASCSubscriptionGroup) async throws -> [SubscriptionInfo] {
        let headers = try ASCMapping.subscriptionHeaders(
            try await http.getAll(ASCPath.subscriptions(group: group.id), query: [Self.limit200]))
        await http.appGuard.allowProducts(Set(headers.map(\.id)))
        var result: [SubscriptionInfo] = []
        for header in headers {
            let territories = try await subscriptionAvailability(subscriptionId: header.id)?.territories ?? []
            let monthly = try await monthlyPlanAvailable(subscriptionId: header.id)
            result.append(SubscriptionInfo(ascId: header.id, productId: header.productId, name: header.name, period: header.period,
                                           state: header.state, groupId: group.id, groupName: group.referenceName,
                                           availableTerritories: territories, monthlyPlanAvailable: monthly,
                                           familySharable: header.familySharable, reviewNote: header.reviewNote,
                                           groupLevel: header.groupLevel))
        }
        return result
    }

    public func regularPrices(subscription: SubscriptionInfo) async throws -> [RegularPriceRow] {
        let pages = try await http.getAll(ASCPath.prices(subscription.ascId), query: [
            URLQueryItem(name: "include", value: "subscriptionPricePoint,territory"), Self.limit200,
        ])
        let rows = try ASCMapping.regularPrices(pages, subscription: subscription)
        await http.appGuard.allowChildren(Set(rows.map(\.ascId)))
        return rows
    }

    public func introductoryOffers(subscription: SubscriptionInfo) async throws -> [IntroOfferRow] {
        let pages = try await http.getAll(ASCPath.introductoryOffers(subscription.ascId), query: [
            URLQueryItem(name: "include", value: "subscriptionPricePoint,territory"), Self.limit200,
        ])
        let rows = try ASCMapping.introductoryOffers(pages, subscription: subscription)
        await http.appGuard.allowChildren(Set(rows.map(\.ascId)))
        return rows
    }

    public func promotionalOffers(subscription: SubscriptionInfo) async throws -> [PromoOffer] {
        let pages = try await http.getAll(ASCPath.promotionalOffers(subscription.ascId), query: [Self.limit200])
        var offers: [PromoOffer] = []
        for resource in pages.flatMap(\.data) {
            await http.appGuard.allowChildren([resource.id])
            let pricePages = try await http.getAll(ASCPath.promotionalOfferPrices(resource.id), query: [
                URLQueryItem(name: "include", value: "subscriptionPricePoint,territory"), Self.limit200,
            ])
            offers.append(try ASCMapping.promotionalOffer(resource, pricePages: pricePages, subscription: subscription))
        }
        return offers.sorted { $0.offerCode < $1.offerCode }
    }

    public func pricePoints(subscriptionId: String, territories: [TerritoryCode], planType: PlanType?) async throws -> [PricePoint] {
        guard !territories.isEmpty else { return [] }
        var query = [
            URLQueryItem(name: "filter[territory]", value: territories.map(\.rawValue).sorted().joined(separator: ",")),
            URLQueryItem(name: "include", value: "territory"),
            Self.limit8000,
        ]
        if let planType { query.insert(URLQueryItem(name: "filter[planType]", value: planType.rawValue), at: 1) }
        let pages = try await http.getAll(ASCPath.subscriptionPricePoints(subscriptionId), query: query)
        return try ASCMapping.pricePoints(pages, productAscId: subscriptionId, planType: planType)
    }

    public func inAppPurchases(appId: String) async throws -> [IAPInfo] {
        let iaps = ASCMapping.inAppPurchases(try await http.getAll(ASCPath.inAppPurchases(app: appId), query: [Self.limit200]))
        await http.appGuard.allowProducts(Set(iaps.map(\.ascId)))
        return iaps
    }

    public func iapPriceSchedule(iapId: String) async throws -> IAPSchedule? {
        let scheduleDocument: JSONAPIDocument
        do {
            scheduleDocument = try await http.get(ASCPath.iapPriceSchedule(iapId), query: [])
        } catch ASCError.http(status: 404, code: _, title: _, detail: _) {
            return nil
        }
        guard let scheduleId = scheduleDocument.data.first?.id else { return nil }
        await http.appGuard.allowChildren([scheduleId])
        let base = try await http.get(ASCPath.iapBaseTerritory(schedule: scheduleId), query: [])
        guard let baseTerritory = base.data.first?.id else {
            throw ASCError.decoding("inAppPurchasePriceSchedules \(scheduleId): no base territory")
        }
        let manualPages = try await http.getAll(ASCPath.iapManualPrices(schedule: scheduleId), query: [
            URLQueryItem(name: "include", value: "inAppPurchasePricePoint,territory"), Self.limit200,
        ])
        let manualPrices = try ASCMapping.iapManualPrices(manualPages)
        await http.appGuard.allowChildren(Set(manualPrices.compactMap(\.ascId)))
        return IAPSchedule(iapId: iapId, scheduleId: scheduleId, baseTerritory: TerritoryCode(baseTerritory), manualPrices: manualPrices)
    }

    public func iapPricePoints(iapId: String, territories: [TerritoryCode]) async throws -> [PricePoint] {
        guard !territories.isEmpty else { return [] }
        let pages = try await http.getAll(ASCPath.iapPricePoints(iapId), query: [
            URLQueryItem(name: "filter[territory]", value: territories.map(\.rawValue).sorted().joined(separator: ",")),
            URLQueryItem(name: "include", value: "territory"),
            Self.limit8000,
        ])
        return try ASCMapping.pricePoints(pages, productAscId: iapId, planType: nil)
    }

    // MARK: - Subscription details

    private func monthlyPlanAvailable(subscriptionId: String) async throws -> Bool {
        do {
            return ASCMapping.hasMonthlyPlan(try await http.getAll(ASCPath.planAvailabilities(subscriptionId), query: [Self.limit200]))
        } catch ASCError.http(status: 404, code: _, title: _, detail: _) {
            return false
        }
    }
}

/// JSON:API -> domain mapping. Pure functions, so recorded fixtures can be checked without HTTP.
enum ASCMapping {
    struct SubscriptionHeader {
        var id: String
        var productId: String
        var name: String
        var period: SubscriptionPeriod
        var state: ProductState
        var familySharable: Bool?
        var reviewNote: String?
        var groupLevel: Int?
    }

    static func app(_ document: JSONAPIDocument) throws -> ASCApp {
        guard let resource = document.data.first, let bundleId = resource.string("bundleId") else {
            throw ASCError.decoding("apps: missing bundleId")
        }
        return ASCApp(id: resource.id, bundleId: bundleId, name: resource.string("name") ?? "")
    }

    static func territories(_ pages: [JSONAPIDocument]) throws -> [ASCTerritory] {
        try pages.flatMap(\.data).map { resource in
            guard let currency = resource.string("currency") else { throw ASCError.decoding("territories \(resource.id): missing currency") }
            return ASCTerritory(id: TerritoryCode(resource.id), currency: CurrencyCode(currency))
        }
    }

    static func groups(_ pages: [JSONAPIDocument]) -> [ASCSubscriptionGroup] {
        pages.flatMap(\.data).map { ASCSubscriptionGroup(id: $0.id, referenceName: $0.string("referenceName") ?? "") }
    }

    static func subscriptionHeaders(_ pages: [JSONAPIDocument]) throws -> [SubscriptionHeader] {
        try pages.flatMap(\.data).map { resource in
            guard let periodRaw = resource.string("subscriptionPeriod"), let period = SubscriptionPeriod(rawValue: periodRaw) else {
                throw ASCError.decoding("subscriptions \(resource.id): unknown subscriptionPeriod")
            }
            return SubscriptionHeader(id: resource.id, productId: resource.string("productId") ?? "", name: resource.string("name") ?? "",
                                      period: period, state: ProductState(resource.string("state") ?? "UNKNOWN"),
                                      familySharable: resource.bool("familySharable"), reviewNote: resource.string("reviewNote"),
                                      groupLevel: resource.int("groupLevel"))
        }
    }

    static func hasMonthlyPlan(_ pages: [JSONAPIDocument]) -> Bool {
        pages.flatMap(\.data).contains { $0.string("planType") == PlanType.monthly.rawValue }
    }

    static func regularPrices(_ pages: [JSONAPIDocument], subscription: SubscriptionInfo) throws -> [RegularPriceRow] {
        try pages.flatMap { page in
            try page.data.map { resource in
                let territory = try relation(resource, "territory")
                let pointId = try relation(resource, "subscriptionPricePoint")
                let rawPlanType = resource.string("planType")
                guard let planType = PlanTypeCanonicalizer.canonical(raw: rawPlanType, monthlyPlanAvailable: subscription.monthlyPlanAvailable) else {
                    throw ASCError.decoding("subscriptionPrices \(resource.id): planType missing on a subscription with MONTHLY availability")
                }
                return RegularPriceRow(ascId: resource.id, subscriptionId: subscription.ascId, territory: TerritoryCode(territory),
                                       planType: planType, rawPlanType: rawPlanType, startDate: try date(resource, "startDate"),
                                       preserved: resource.bool("preserved") ?? false, pricePointId: pointId,
                                       customerPrice: try price(page, type: "subscriptionPricePoints", id: pointId))
            }
        }
    }

    static func introductoryOffers(_ pages: [JSONAPIDocument], subscription: SubscriptionInfo) throws -> [IntroOfferRow] {
        try pages.flatMap { page in
            try page.data.map { resource in
                let territory = try relation(resource, "territory")
                let (mode, duration, periods) = try offerTerms(resource)
                let rawPlanType = resource.string("targetSubscriptionPlanType")
                guard let planType = PlanTypeCanonicalizer.canonical(raw: rawPlanType, monthlyPlanAvailable: subscription.monthlyPlanAvailable) else {
                    throw ASCError.decoding("subscriptionIntroductoryOffers \(resource.id): targetSubscriptionPlanType missing on a subscription with MONTHLY availability")
                }
                let pointId = resource.relatedID("subscriptionPricePoint")
                if mode != .freeTrial && pointId == nil {
                    throw ASCError.decoding("subscriptionIntroductoryOffers \(resource.id): paid offer without price point")
                }
                return IntroOfferRow(ascId: resource.id, subscriptionId: subscription.ascId, territory: TerritoryCode(territory),
                                     planType: planType, rawPlanType: rawPlanType, mode: mode, duration: duration,
                                     numberOfPeriods: periods, startDate: try date(resource, "startDate"),
                                     endDate: try date(resource, "endDate"), pricePointId: pointId,
                                     customerPrice: try pointId.map { try price(page, type: "subscriptionPricePoints", id: $0) })
            }
        }
    }

    static func promotionalOffer(_ resource: JSONAPIResource, pricePages: [JSONAPIDocument], subscription: SubscriptionInfo) throws -> PromoOffer {
        let (mode, duration, periods) = try offerTerms(resource)
        let rawPlanType = resource.string("targetSubscriptionPlanType")
        guard let planType = PlanTypeCanonicalizer.canonical(raw: rawPlanType, monthlyPlanAvailable: subscription.monthlyPlanAvailable) else {
            throw ASCError.decoding("subscriptionPromotionalOffers \(resource.id): targetSubscriptionPlanType missing on a subscription with MONTHLY availability")
        }
        guard let offerCode = resource.string("offerCode") else {
            throw ASCError.decoding("subscriptionPromotionalOffers \(resource.id): missing offerCode")
        }
        let prices = try pricePages.flatMap { page in
            try page.data.map { price in
                let pointId = price.relatedID("subscriptionPricePoint")
                let customerPrice = pointId.flatMap {
                    page.includedResource(type: "subscriptionPricePoints", id: $0)?.string("customerPrice")
                }
                // A paid row needs its included price point (as in M0); FREE_TRIAL rows ignore any echoed point (O4, S7).
                if mode != .freeTrial, let pointId, customerPrice == nil {
                    throw ASCError.decoding("subscriptionPricePoints \(pointId): not included or missing customerPrice")
                }
                return try PromoPriceMapping.make(rowId: price.id, territoryId: price.relatedID("territory"), pricePointId: pointId,
                                                  customerPrice: customerPrice, offerMode: mode)
            }
        }
        return PromoOffer(ascId: resource.id, subscriptionId: subscription.ascId, offerCode: offerCode, name: resource.string("name") ?? "",
                          mode: mode, duration: duration, numberOfPeriods: periods, planType: planType, prices: prices)
    }

    static func pricePoints(_ pages: [JSONAPIDocument], productAscId: String, planType: PlanType?) throws -> [PricePoint] {
        try pages.flatMap(\.data).map { resource in
            guard let customer = decimal(resource.string("customerPrice")) else {
                throw ASCError.decoding("\(resource.type) \(resource.id): missing customerPrice")
            }
            return PricePoint(id: resource.id, productAscId: productAscId, territory: TerritoryCode(try relation(resource, "territory")),
                              planType: planType, customerPrice: customer, proceeds: decimal(resource.string("proceeds")))
        }
    }

    static func inAppPurchases(_ pages: [JSONAPIDocument]) -> [IAPInfo] {
        pages.flatMap(\.data).map { resource in
            IAPInfo(ascId: resource.id, productId: resource.string("productId") ?? "", name: resource.string("name") ?? "",
                    iapType: resource.string("inAppPurchaseType") ?? "", state: ProductState(resource.string("state") ?? "UNKNOWN"),
                    familySharable: resource.bool("familySharable"), reviewNote: resource.string("reviewNote"))
        }
    }

    static func iapManualPrices(_ pages: [JSONAPIDocument]) throws -> [IAPManualPrice] {
        try pages.flatMap { page in
            try page.data.map { resource in
                let pointId = resource.relatedID("inAppPurchasePricePoint")
                return try IAPManualPriceMapping.make(
                    rowId: resource.id, territoryId: resource.relatedID("territory"), pricePointId: pointId,
                    startDate: resource.string("startDate"), endDate: resource.string("endDate"),
                    customerPrice: pointId.flatMap {
                        page.includedResource(type: "inAppPurchasePricePoints", id: $0)?.string("customerPrice")
                    })
            }
        }
    }

    // MARK: - Helpers

    static func decimal(_ text: String?) -> Decimal? {
        guard let text, !text.isEmpty else { return nil }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func relation(_ resource: JSONAPIResource, _ name: String) throws -> String {
        guard let id = resource.relatedID(name) else { throw ASCError.decoding("\(resource.type) \(resource.id): missing \(name) linkage") }
        return id
    }

    private static func date(_ resource: JSONAPIResource, _ key: String) throws -> CalendarDate? {
        guard let text = resource.string(key) else { return nil }
        guard let date = CalendarDate(iso: text) else { throw ASCError.decoding("\(resource.type) \(resource.id): bad \(key) \(text)") }
        return date
    }

    private static func price(_ page: JSONAPIDocument, type: String, id: String) throws -> Decimal {
        guard let point = page.includedResource(type: type, id: id), let value = decimal(point.string("customerPrice")) else {
            throw ASCError.decoding("\(type) \(id): not included or missing customerPrice")
        }
        return value
    }

    private static func offerTerms(_ resource: JSONAPIResource) throws -> (OfferMode, OfferDuration, Int) {
        guard let mode = resource.string("offerMode").flatMap(OfferMode.init(rawValue:)),
              let duration = resource.string("duration").flatMap(OfferDuration.init(rawValue:)) else {
            throw ASCError.decoding("\(resource.type) \(resource.id): unknown offerMode or duration")
        }
        return (mode, duration, resource.int("numberOfPeriods") ?? 1)
    }
}
