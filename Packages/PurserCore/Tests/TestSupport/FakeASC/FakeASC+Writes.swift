import Foundation
import Domain
import ASCClient

extension FakeASC {
    typealias JSONObject = [String: Any]

    func parse(_ body: Data?) throws -> (data: JSONObject, included: [JSONObject]) {
        guard let body, let root = try? JSONSerialization.jsonObject(with: body) as? JSONObject,
              let data = root["data"] as? JSONObject else {
            throw FakeRejection(reply: error(400, code: "PARAMETER_ERROR.INVALID", title: "Invalid body", detail: "Not a JSON:API document"))
        }
        return (data, root["included"] as? [JSONObject] ?? [])
    }

    func relId(_ resource: JSONObject, _ name: String) -> String? {
        guard let relationship = (resource["relationships"] as? JSONObject)?[name] as? JSONObject else { return nil }
        return (relationship["data"] as? JSONObject)?["id"] as? String
    }

    func relIds(_ resource: JSONObject, _ name: String) -> [String] {
        guard let relationship = (resource["relationships"] as? JSONObject)?[name] as? JSONObject,
              let items = relationship["data"] as? [JSONObject] else { return [] }
        return items.compactMap { $0["id"] as? String }
    }

    func attributes(_ resource: JSONObject) -> JSONObject { resource["attributes"] as? JSONObject ?? [:] }

    /// Missing or null -> nil; a malformed date is rejected.
    func date(_ attributes: JSONObject, _ key: String) throws -> CalendarDate? {
        guard let raw = attributes[key] as? String else { return nil }
        guard let value = CalendarDate(iso: raw) else { throw conflict("ENTITY_ERROR.ATTRIBUTE.INVALID", "\(key) is not a valid date") }
        return value
    }

    func subscription(_ id: String?) throws -> FakeSubscription {
        guard let id, let sub = model.subscriptions.first(where: { $0.id == id }) else {
            throw conflict("ENTITY_ERROR.RELATIONSHIP.INVALID", "The subscription does not exist")
        }
        return sub
    }

    func pricePoint(_ id: String, product: String, territory: TerritoryCode?) throws -> FakePricePoint {
        guard let point = model.pricePoints.first(where: { $0.id == id }), point.productId == product,
              territory.map({ point.territory == $0 }) ?? true else {
            throw conflict("ENTITY_ERROR.RELATIONSHIP.INVALID", "The price point does not belong to this product and territory")
        }
        return point
    }

    func requireAvailable(_ sub: FakeSubscription, _ territory: TerritoryCode) throws {
        guard sub.availableTerritories.contains(territory) else {
            throw conflict("ENTITY_ERROR.RELATIONSHIP.INVALID", "The territory is not available for this subscription")
        }
    }

    func handleWrite(method: String, path: String, body: Data?) throws -> FakeReply {
        let c = components(path)
        if let reply = try handleLocalizationWrite(method: method, path: path, body: body) { return reply }
        if method == "POST", capture(c, ["v1", "subscriptionPrices"]) != nil { return try postRegular(body) }
        if method == "DELETE", let id = capture(c, ["v1", "subscriptionPrices", "*"]) { return try deleteRegular(id) }
        if method == "POST", capture(c, ["v1", "subscriptionIntroductoryOffers"]) != nil { return try postIntro(body) }
        if method == "PATCH", let id = capture(c, ["v1", "subscriptionIntroductoryOffers", "*"]) { return try patchIntro(id, body) }
        if method == "DELETE", let id = capture(c, ["v1", "subscriptionIntroductoryOffers", "*"]) { return try deleteIntro(id) }
        if method == "POST", capture(c, ["v1", "subscriptionPromotionalOffers"]) != nil { return try postPromo(body) }
        if method == "PATCH", let id = capture(c, ["v1", "subscriptionPromotionalOffers", "*"]) { return try patchPromo(id, body) }
        if method == "DELETE", let id = capture(c, ["v1", "subscriptionPromotionalOffers", "*"]) { return try deletePromo(id) }
        if method == "POST", capture(c, ["v1", "inAppPurchasePriceSchedules"]) != nil { return try postSchedule(body) }
        if let reply = try handleProductWrite(method: method, components: c, body: body) { return reply }
        if method == "POST", let kind = metadataVersionKind(c) { return try postMetadataVersion(kind, body) }
        throw notFound()
    }

    // MARK: Regular prices

    func postRegular(_ body: Data?) throws -> FakeReply {
        let (data, _) = try parse(body)
        let a = attributes(data)
        let sub = try subscription(relId(data, "subscription"))
        guard let pointId = relId(data, "subscriptionPricePoint") else {
            throw conflict("ENTITY_ERROR.RELATIONSHIP.REQUIRED", "The relationship 'subscriptionPricePoint' is required")
        }
        let explicitTerritory = relId(data, "territory").map { TerritoryCode($0) }
        let point = try pricePoint(pointId, product: sub.id, territory: explicitTerritory)
        let territory = point.territory
        try requireAvailable(sub, territory)
        let planType = (a["planType"] as? String).flatMap(PlanType.init(rawValue:)) ?? .upfront
        let preserve = a["preserveCurrentPrice"] as? Bool ?? false
        let start = try date(a, "startDate")
        let today = self.today
        let cell = model.regularPrices.filter { $0.subscriptionId == sub.id && $0.territory == territory && $0.planType == planType }
        if let start, start < today { throw conflict("ENTITY_ERROR.ATTRIBUTE.INVALID", "startDate must not be in the past") }
        if start == nil, !cell.isEmpty {
            throw conflict("ENTITY_ERROR.ATTRIBUTE.INVALID", "startDate is required when the subscription already has a price")
        }
        if cell.contains(where: { $0.startDate.map { $0 > today } ?? false }) {
            throw conflict("ENTITY_ERROR", "Must delete future price change before creating a new one")
        }
        let row = FakeRegularPrice(id: nextId("price"), subscriptionId: sub.id, territory: territory, planType: planType,
                                   sendsPlanType: true, startDate: start, preserved: preserve, pricePointId: pointId)
        model.regularPrices.append(row)
        return FakeReply(status: 201, body: single(regularResource(row)), applied: true)
    }

    func deleteRegular(_ id: String) throws -> FakeReply {
        guard let index = model.regularPrices.firstIndex(where: { $0.id == id }) else { throw notFound() }
        let row = model.regularPrices[index]
        guard let start = row.startDate,
              start.startOfDayUTC.timeIntervalSince(now()) >= Double(appleDeleteCutoffHours) * 3600 else {
            throw conflict("ENTITY_ERROR", "Only future price changes can be deleted")
        }
        model.regularPrices.remove(at: index)
        return FakeReply(status: 204, body: nil, applied: true)
    }

    // MARK: Introductory offers

    func overlaps(_ aStart: CalendarDate, _ aEnd: CalendarDate?, _ bStart: CalendarDate, _ bEnd: CalendarDate?) -> Bool {
        (bEnd.map { aStart < $0 } ?? true) && (aEnd.map { bStart < $0 } ?? true)
    }

    func liveIntros(subscriptionId: String, territory: TerritoryCode, planType: PlanType, excluding: String?) -> [FakeIntro] {
        let today = self.today
        return model.intros.filter {
            $0.subscriptionId == subscriptionId && $0.territory == territory && $0.planType == planType && $0.id != excluding
                && ($0.endDate.map { $0 > today } ?? true)
        }
    }

    func postIntro(_ body: Data?) throws -> FakeReply {
        let (data, _) = try parse(body)
        let a = attributes(data)
        let sub = try subscription(relId(data, "subscription"))
        guard let territoryId = relId(data, "territory") else {
            throw conflict("ENTITY_ERROR.RELATIONSHIP.REQUIRED", "The relationship 'territory' is required")
        }
        let territory = TerritoryCode(territoryId)
        try requireAvailable(sub, territory)
        guard let mode = (a["offerMode"] as? String).flatMap(OfferMode.init(rawValue:)),
              let duration = (a["duration"] as? String).flatMap(OfferDuration.init(rawValue:)) else {
            throw conflict("ENTITY_ERROR.ATTRIBUTE.INVALID", "offerMode and duration are required")
        }
        let periods = a["numberOfPeriods"] as? Int ?? 1
        let planType = (a["targetSubscriptionPlanType"] as? String).flatMap(PlanType.init(rawValue:)) ?? .upfront
        let pointId = relId(data, "subscriptionPricePoint")
        if mode == .freeTrial, pointId != nil { throw conflict("ENTITY_ERROR.ATTRIBUTE.INVALID", "A free trial cannot have a price point") }
        if mode != .freeTrial, pointId == nil { throw conflict("ENTITY_ERROR.RELATIONSHIP.REQUIRED", "The relationship 'subscriptionPricePoint' is required") }
        if let pointId { _ = try pricePoint(pointId, product: sub.id, territory: territory) }
        let start = try date(a, "startDate")
        let end = try date(a, "endDate")
        let today = self.today
        if let start, start < today { throw conflict("ENTITY_ERROR.ATTRIBUTE.INVALID", "startDate must not be in the past") }
        let effectiveStart = start ?? today
        if let end, end <= effectiveStart { throw conflict("ENTITY_ERROR.ATTRIBUTE.INVALID", "endDate must be after startDate") }
        let live = liveIntros(subscriptionId: sub.id, territory: territory, planType: planType, excluding: nil)
        let isCurrent = effectiveStart <= today
        if live.contains(where: { ($0.effectiveStart <= today) == isCurrent }) {
            throw conflict("ENTITY_ERROR", "Only one current and one future introductory offer are allowed per territory")
        }
        if live.contains(where: { overlaps(effectiveStart, end, $0.effectiveStart, $0.endDate) }) {
            throw conflict("ENTITY_ERROR", "The introductory offer overlaps an existing offer")
        }
        let row = FakeIntro(id: nextId("intro"), subscriptionId: sub.id, territory: territory, planType: planType, mode: mode,
                            duration: duration, numberOfPeriods: periods, startDate: start, endDate: end, pricePointId: pointId,
                            createdOn: today)
        model.intros.append(row)
        return FakeReply(status: 201, body: single(introResource(row)), applied: true)
    }

    func patchIntro(_ id: String, _ body: Data?) throws -> FakeReply {
        guard let index = model.intros.firstIndex(where: { $0.id == id }) else { throw notFound() }
        let (data, _) = try parse(body)
        let a = attributes(data)
        guard a.keys.contains("endDate"), Set(a.keys).subtracting(["endDate"]).isEmpty else {
            throw conflict("ENTITY_ERROR.ATTRIBUTE.INVALID", "Only endDate can be changed")
        }
        var row = model.intros[index]
        let end = try date(a, "endDate")
        if let end {
            if end < today { throw conflict("ENTITY_ERROR.ATTRIBUTE.INVALID", "endDate must not be in the past") }
            if end <= row.effectiveStart { throw conflict("ENTITY_ERROR.ATTRIBUTE.INVALID", "endDate must be after startDate") }
        }
        let others = liveIntros(subscriptionId: row.subscriptionId, territory: row.territory, planType: row.planType, excluding: id)
        if others.contains(where: { overlaps(row.effectiveStart, end, $0.effectiveStart, $0.endDate) }) {
            throw conflict("ENTITY_ERROR", "The introductory offer overlaps an existing offer")
        }
        row.endDate = end
        model.intros[index] = row
        return FakeReply(status: 200, body: single(introResource(row)), applied: true)
    }

    func deleteIntro(_ id: String) throws -> FakeReply {
        guard let index = model.intros.firstIndex(where: { $0.id == id }) else { throw notFound() }
        model.intros.remove(at: index)
        return FakeReply(status: 204, body: nil, applied: true)
    }

    // MARK: Promotional offers

    func promoPrices(_ data: JSONObject, _ included: [JSONObject], mode: OfferMode, subscriptionId: String) throws -> [FakePromoPrice] {
        var prices: [FakePromoPrice] = []
        for localId in relIds(data, "prices") {
            guard let item = included.first(where: { $0["id"] as? String == localId }) else {
                throw conflict("ENTITY_ERROR.RELATIONSHIP.INVALID", "Included price \(localId) is missing")
            }
            guard let territoryId = relId(item, "territory") else {
                throw conflict("ENTITY_ERROR.RELATIONSHIP.REQUIRED", "The relationship 'territory' is required")
            }
            let territory = TerritoryCode(territoryId)
            let pointId = relId(item, "subscriptionPricePoint")
            if mode == .freeTrial, pointId != nil { throw conflict("ENTITY_ERROR.ATTRIBUTE.INVALID", "A free trial price cannot have a price point") }
            if mode != .freeTrial, pointId == nil { throw conflict("ENTITY_ERROR.RELATIONSHIP.REQUIRED", "The relationship 'subscriptionPricePoint' is required") }
            if let pointId { _ = try pricePoint(pointId, product: subscriptionId, territory: territory) }
            prices.append(FakePromoPrice(id: nextId("promoprice"), territory: territory, pricePointId: pointId))
        }
        return prices.sorted { $0.territory < $1.territory }
    }

    func promoDocument(_ offer: FakePromo, status: Int) -> FakeReply {
        var included: [String: JSONBody] = [:]
        for price in offer.prices { included["prices|\(price.id)"] = promoPriceResource(price) }
        return FakeReply(status: status, body: single(promoResource(offer), included: included), applied: true)
    }

    func postPromo(_ body: Data?) throws -> FakeReply {
        let (data, included) = try parse(body)
        let a = attributes(data)
        let sub = try subscription(relId(data, "subscription"))
        guard let code = a["offerCode"] as? String, !code.isEmpty,
              let mode = (a["offerMode"] as? String).flatMap(OfferMode.init(rawValue:)),
              let duration = (a["duration"] as? String).flatMap(OfferDuration.init(rawValue:)) else {
            throw conflict("ENTITY_ERROR.ATTRIBUTE.INVALID", "offerCode, offerMode and duration are required")
        }
        if model.usedOfferCodes.contains(code) {
            throw conflict(Self.offerCodeReuseError.code, Self.offerCodeReuseError.detail)
        }
        if model.promos.filter({ $0.subscriptionId == sub.id }).count >= AppleConstants.maxPromoOffersPerSubscription {
            throw conflict("ENTITY_ERROR", "The maximum number of promotional offers has been reached")
        }
        let prices = try promoPrices(data, included, mode: mode, subscriptionId: sub.id)
        let offer = FakePromo(id: nextId("promo"), subscriptionId: sub.id, offerCode: code, name: a["name"] as? String ?? code,
                              mode: mode, duration: duration, numberOfPeriods: a["numberOfPeriods"] as? Int ?? 1,
                              planType: (a["targetSubscriptionPlanType"] as? String).flatMap(PlanType.init(rawValue:)) ?? .upfront,
                              prices: prices)
        model.promos.append(offer)
        model.usedOfferCodes.insert(code)
        return promoDocument(offer, status: 201)
    }

    func patchPromo(_ id: String, _ body: Data?) throws -> FakeReply {
        guard let index = model.promos.firstIndex(where: { $0.id == id }) else { throw notFound() }
        let (data, included) = try parse(body)
        guard attributes(data).isEmpty else { throw conflict("ENTITY_ERROR.ATTRIBUTE.INVALID", "Only prices can be changed") }
        var offer = model.promos[index]
        let patch = try promoPrices(data, included, mode: offer.mode, subscriptionId: offer.subscriptionId)
        let merged = PromoPriceSemantics.applyPatch(
            existing: offer.prices.map { NewPromoPrice(territory: $0.territory, pricePointId: $0.pricePointId) },
            patch: patch.map { NewPromoPrice(territory: $0.territory, pricePointId: $0.pricePointId) },
            replaces: AppleConstants.promoPatchReplacesPriceSet)
        let rows = Dictionary((offer.prices + patch).map { ($0.territory, $0) }, uniquingKeysWith: { _, patched in patched })
        offer.prices = merged.compactMap { rows[$0.territory] }
        model.promos[index] = offer
        return promoDocument(offer, status: 200)
    }

    func deletePromo(_ id: String) throws -> FakeReply {
        guard let index = model.promos.firstIndex(where: { $0.id == id }) else { throw notFound() }
        model.promos.remove(at: index)
        return FakeReply(status: 204, body: nil, applied: true)
    }

    // MARK: IAP price schedule

    func postSchedule(_ body: Data?) throws -> FakeReply {
        let (data, included) = try parse(body)
        guard let iapId = relId(data, "inAppPurchase"), model.iaps.contains(where: { $0.id == iapId }) else {
            throw conflict("ENTITY_ERROR.RELATIONSHIP.INVALID", "The in-app purchase does not exist")
        }
        guard let base = relId(data, "baseTerritory") else {
            throw conflict("ENTITY_ERROR.RELATIONSHIP.REQUIRED", "The relationship 'baseTerritory' is required")
        }
        var manual: [FakeIAPManualPrice] = []
        for localId in relIds(data, "manualPrices") {
            guard let item = included.first(where: { $0["id"] as? String == localId }),
                  let pointId = relId(item, "inAppPurchasePricePoint") else {
                throw conflict("ENTITY_ERROR.RELATIONSHIP.REQUIRED", "Manual price \(localId) needs a price point")
            }
            let point = try pricePoint(pointId, product: iapId, territory: nil)
            let a = attributes(item)
            manual.append(FakeIAPManualPrice(id: nextId("iapprice"), territory: point.territory, pricePointId: pointId,
                                             startDate: try date(a, "startDate") ?? (iapNullStartEchoesCreationDay ? today : nil),
                                             endDate: try date(a, "endDate")))
        }
        let schedule = FakeIAPSchedule(id: nextId("sched"), iapId: iapId, baseTerritory: TerritoryCode(base), manualPrices: manual)
        model.iapSchedules.removeAll { $0.iapId == iapId }
        model.iapSchedules.append(schedule)
        return FakeReply(status: 201, body: single(resource("inAppPurchasePriceSchedules", schedule.id, attributes: [:])), applied: true)
    }
}

extension FakeASC {
    /// Spike S7: code and detail of the 409 Apple returned for a reused offer code
    /// (Fixtures/spikes/S7/promo-code-reuse-response.json); M2's built-in reply when S7 recorded no 409.
    public static let offerCodeReuseError: (code: String, detail: String) = {
        guard let data = try? Fixtures.data("spikes/S7/promo-code-reuse-response.json"),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (root["errors"] as? [[String: Any]])?.first,
              let code = first["code"] as? String, let detail = first["detail"] as? String else {
            return ("ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE", "The offerCode has already been used")
        }
        return (code, detail)
    }()
}
