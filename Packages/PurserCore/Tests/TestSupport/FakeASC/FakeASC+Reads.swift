import Foundation
import Domain
import ASCClient

extension FakeASC {
    func ident(_ type: String, _ id: String) -> JSONBody { .object(["type": .string(type), "id": .string(id)]) }
    func rel(_ type: String, _ id: String?) -> JSONBody { .object(["data": id.map { ident(type, $0) } ?? .null]) }
    func dateJSON(_ date: CalendarDate?) -> JSONBody { date.map { .string($0.iso) } ?? .null }
    func money(_ amount: Decimal) -> JSONBody { .string("\(amount)") }

    func resource(_ type: String, _ id: String, attributes: [String: JSONBody], relationships: [String: JSONBody] = [:]) -> JSONBody {
        var object: [String: JSONBody] = ["type": .string(type), "id": .string(id), "attributes": .object(attributes)]
        if !relationships.isEmpty { object["relationships"] = .object(relationships) }
        return .object(object)
    }

    func territoryResource(_ code: TerritoryCode) -> JSONBody {
        resource("territories", code.rawValue, attributes: ["currency": .string(model.territories[code]?.rawValue ?? "USD")])
    }

    func pricePointResource(_ point: FakePricePoint) -> JSONBody {
        let type = point.planType == nil ? "inAppPurchasePricePoints" : "subscriptionPricePoints"
        return resource(type, point.id, attributes: ["customerPrice": money(point.customerPrice), "proceeds": money(point.proceeds),
                                                     "proceedsYear2": money(point.proceeds)],
                        relationships: ["territory": rel("territories", point.territory.rawValue)])
    }

    func pointIncluded(_ pointId: String?, territory: TerritoryCode) -> [String: JSONBody] {
        var included: [String: JSONBody] = ["territories|\(territory.rawValue)": territoryResource(territory)]
        if let pointId, let point = model.pricePoints.first(where: { $0.id == pointId }) {
            included["points|\(point.id)"] = pricePointResource(point)
        }
        return included
    }

    func regularResource(_ row: FakeRegularPrice) -> JSONBody {
        var attributes: [String: JSONBody] = ["startDate": dateJSON(row.startDate), "preserved": .bool(row.preserved)]
        if row.sendsPlanType { attributes["planType"] = .string(row.planType.rawValue) }
        return resource("subscriptionPrices", row.id, attributes: attributes, relationships: [
            "subscriptionPricePoint": rel("subscriptionPricePoints", row.pricePointId),
            "territory": rel("territories", row.territory.rawValue),
        ])
    }

    func introResource(_ row: FakeIntro) -> JSONBody {
        resource("subscriptionIntroductoryOffers", row.id, attributes: [
            "duration": .string(row.duration.rawValue), "offerMode": .string(row.mode.rawValue),
            "numberOfPeriods": .int(row.numberOfPeriods), "startDate": dateJSON(row.startDate), "endDate": dateJSON(row.endDate),
            "targetSubscriptionPlanType": .string(row.planType.rawValue),
        ], relationships: [
            "territory": rel("territories", row.territory.rawValue),
            "subscriptionPricePoint": rel("subscriptionPricePoints", row.pricePointId),
        ])
    }

    func promoResource(_ offer: FakePromo) -> JSONBody {
        resource("subscriptionPromotionalOffers", offer.id, attributes: [
            "name": .string(offer.name), "offerCode": .string(offer.offerCode), "duration": .string(offer.duration.rawValue),
            "offerMode": .string(offer.mode.rawValue), "numberOfPeriods": .int(offer.numberOfPeriods),
            "targetSubscriptionPlanType": .string(offer.planType.rawValue),
        ])
    }

    func promoPriceResource(_ price: FakePromoPrice) -> JSONBody {
        resource("subscriptionPromotionalOfferPrices", price.id, attributes: [:], relationships: [
            "territory": rel("territories", price.territory.rawValue),
            "subscriptionPricePoint": rel("subscriptionPricePoints", price.pricePointId),
        ])
    }

    func single(_ resource: JSONBody, included: [String: JSONBody] = [:], url: String? = nil) -> JSONBody {
        var document: [String: JSONBody] = ["data": resource]
        if let url { document["links"] = .object(["self": .string(url)]) }
        if !included.isEmpty { document["included"] = .array(included.keys.sorted().map { included[$0]! }) }
        return .object(document)
    }

    func page(_ entries: [(resource: JSONBody, included: [String: JSONBody])], url: URL, query: [String: String]) -> JSONBody {
        let limit = max(1, Int(query["limit"] ?? "") ?? 50)
        let start = min(Int(query["cursor"] ?? "") ?? 0, entries.count)
        let end = min(start + limit, entries.count)
        let slice = entries[start..<end]
        var included: [String: JSONBody] = [:]
        for entry in slice { included.merge(entry.included) { first, _ in first } }
        var links: [String: JSONBody] = ["self": .string(url.absoluteString)]
        if end < entries.count, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            var items = (parts.queryItems ?? []).filter { $0.name != "cursor" }
            items.append(URLQueryItem(name: "cursor", value: String(end)))
            parts.queryItems = items
            if let next = parts.url { links["next"] = .string(next.absoluteString) }
        }
        var document: [String: JSONBody] = [
            "data": .array(slice.map(\.resource)),
            "links": .object(links),
            "meta": .object(["paging": .object(["total": .int(entries.count), "limit": .int(limit)])]),
        ]
        if !included.isEmpty { document["included"] = .array(included.keys.sorted().map { included[$0]! }) }
        return .object(document)
    }

    func territoryFilter(_ query: [String: String]) -> Set<TerritoryCode>? {
        guard let raw = query["filter[territory]"], !raw.isEmpty else { return nil }
        return Set(raw.split(separator: ",").map { TerritoryCode(String($0)) })
    }

    func handleRead(url: URL, query: [String: String]) throws -> FakeReply {
        let c = components(url.path)
        let ok = { (body: JSONBody) in FakeReply(status: 200, body: body, applied: false) }
        let territories = territoryFilter(query)

        if let id = capture(c, ["v1", "apps", "*"]) {
            guard id == model.app.id else { throw notFound() }
            return ok(single(resource("apps", id, attributes: ["bundleId": .string(model.app.bundleId), "name": .string(model.app.name)]),
                             url: url.absoluteString))
        }
        if capture(c, ["v1", "territories"]) != nil {
            return ok(page(model.territories.keys.sorted().map { (territoryResource($0), [:]) }, url: url, query: query))
        }
        if let id = capture(c, ["v1", "apps", "*", "subscriptionGroups"]) {
            guard id == model.app.id else { throw notFound() }
            return ok(page(model.groups.map { (resource("subscriptionGroups", $0.id, attributes: ["referenceName": .string($0.name)]), [:]) },
                           url: url, query: query))
        }
        if let id = capture(c, ["v1", "subscriptionGroups", "*", "subscriptions"]) {
            let subs = model.subscriptions.filter { $0.groupId == id }
            return ok(page(subs.enumerated().map { index, sub in
                (resource("subscriptions", sub.id, attributes: [
                    "name": .string(sub.name), "productId": .string(sub.productId), "state": .string(sub.state.rawValue),
                    "subscriptionPeriod": .string(sub.period.rawValue), "groupLevel": .int(index + 1), "familySharable": .bool(false),
                ]), [:])
            }, url: url, query: query))
        }
        if let id = capture(c, ["v1", "subscriptions", "*", "subscriptionAvailability"]) {
            guard model.subscriptions.contains(where: { $0.id == id }) else { throw notFound() }
            return ok(single(resource("subscriptionAvailabilities", "avail-\(id)", attributes: ["availableInNewTerritories": .bool(false)]),
                             url: url.absoluteString))
        }
        if let id = capture(c, ["v1", "subscriptionAvailabilities", "*", "availableTerritories"]) {
            let subId = String(id.dropFirst("avail-".count))
            guard let sub = model.subscriptions.first(where: { $0.id == subId }) else { throw notFound() }
            return ok(page(sub.availableTerritories.sorted().map { (territoryResource($0), [:]) }, url: url, query: query))
        }
        if capture(c, ["v1", "subscriptions", "*", "planAvailabilities"]) != nil {
            return ok(page([], url: url, query: query))
        }
        if let id = capture(c, ["v1", "subscriptions", "*", "prices"]) {
            let planFilter = query["filter[planType]"].flatMap(PlanType.init(rawValue:))
            let rows = model.regularPrices.filter { row in
                row.subscriptionId == id && (territories?.contains(row.territory) ?? true) && (planFilter.map { row.planType == $0 } ?? true)
            }
            return ok(page(rows.map { (regularResource($0), pointIncluded($0.pricePointId, territory: $0.territory)) }, url: url, query: query))
        }
        if let id = capture(c, ["v1", "subscriptions", "*", "introductoryOffers"]) {
            let rows = model.intros.filter { $0.subscriptionId == id && (territories?.contains($0.territory) ?? true) }
            return ok(page(rows.map { (introResource($0), pointIncluded($0.pricePointId, territory: $0.territory)) }, url: url, query: query))
        }
        if let id = capture(c, ["v1", "subscriptions", "*", "promotionalOffers"]) {
            return ok(page(model.promos.filter { $0.subscriptionId == id }.map { (promoResource($0), [:]) }, url: url, query: query))
        }
        if let id = capture(c, ["v1", "subscriptionPromotionalOffers", "*", "prices"]) {
            guard let offer = model.promos.first(where: { $0.id == id }) else { throw notFound() }
            return ok(page(offer.prices.map { (promoPriceResource($0), pointIncluded($0.pricePointId, territory: $0.territory)) },
                           url: url, query: query))
        }
        if let id = capture(c, ["v1", "subscriptions", "*", "pricePoints"]) {
            let planFilter = query["filter[planType]"].flatMap(PlanType.init(rawValue:))
            let points = model.pricePoints.filter { point in
                point.productId == id && (territories?.contains(point.territory) ?? true) && (planFilter.map { point.planType == $0 } ?? true)
            }
            return ok(page(points.map { (pricePointResource($0), ["territories|\($0.territory.rawValue)": territoryResource($0.territory)]) },
                           url: url, query: query))
        }
        if let id = capture(c, ["v1", "apps", "*", "inAppPurchasesV2"]) {
            guard id == model.app.id else { throw notFound() }
            return ok(page(model.iaps.map {
                (resource("inAppPurchases", $0.id, attributes: ["name": .string($0.name), "productId": .string($0.productId),
                                                                "inAppPurchaseType": .string($0.type), "state": .string($0.state.rawValue)]), [:])
            }, url: url, query: query))
        }
        if let id = capture(c, ["v2", "inAppPurchases", "*", "iapPriceSchedule"]) {
            guard let schedule = model.iapSchedules.first(where: { $0.iapId == id }) else { throw notFound() }
            return ok(single(resource("inAppPurchasePriceSchedules", schedule.id, attributes: [:]), url: url.absoluteString))
        }
        if let id = capture(c, ["v1", "inAppPurchasePriceSchedules", "*", "manualPrices"]) {
            guard let schedule = model.iapSchedules.first(where: { $0.id == id }) else { throw notFound() }
            return ok(page(schedule.manualPrices.map { price in
                (resource("inAppPurchasePrices", price.id,
                          attributes: ["startDate": dateJSON(price.startDate), "endDate": dateJSON(price.endDate), "manual": .bool(true)],
                          relationships: ["inAppPurchasePricePoint": rel("inAppPurchasePricePoints", price.pricePointId),
                                          "territory": rel("territories", price.territory.rawValue)]),
                 pointIncluded(price.pricePointId, territory: price.territory))
            }, url: url, query: query))
        }
        if let id = capture(c, ["v1", "inAppPurchasePriceSchedules", "*", "baseTerritory"]) {
            guard let schedule = model.iapSchedules.first(where: { $0.id == id }) else { throw notFound() }
            return ok(single(territoryResource(schedule.baseTerritory), url: url.absoluteString))
        }
        if let id = capture(c, ["v2", "inAppPurchases", "*", "pricePoints"]) {
            let points = model.pricePoints.filter { $0.productId == id && (territories?.contains($0.territory) ?? true) }
            return ok(page(points.map { (pricePointResource($0), ["territories|\($0.territory.rawValue)": territoryResource($0.territory)]) },
                           url: url, query: query))
        }
        throw notFound()
    }
}
