import Foundation
import Domain

/// Minimal JSON value for JSON:API request bodies. Encoded with sorted keys so bodies are byte-stable.
package indirect enum JSONBody: Encodable, Equatable, Sendable {
    case object([String: JSONBody])
    case array([JSONBody])
    case string(String)
    case int(Int)
    case bool(Bool)
    case null

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    package func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

package enum WriteBodyError: Error, Equatable, Sendable {
    case missingPricePoint(TerritoryCode)
    case freeTrialWithPricePoint(TerritoryCode)
}

/// Request bodies for every write Purser makes. STRUCT rules R1, I1, I3, O4 and L1 live here.
package enum WriteBodies {
    static func ref(_ type: String, _ id: String) -> JSONBody {
        .object(["data": .object(["type": .string(type), "id": .string(id)])])
    }

    static func date(_ value: CalendarDate?) -> JSONBody {
        value.map { .string($0.iso) } ?? .null
    }

    /// R1: planType and preserveCurrentPrice are always present; startDate nil is sent as explicit null.
    package static func createRegularPrice(_ r: NewRegularPrice) -> JSONBody {
        .object(["data": .object([
            "type": .string("subscriptionPrices"),
            "attributes": .object([
                "startDate": date(r.startDate),
                "preserveCurrentPrice": .bool(r.preserveCurrentPrice),
                "planType": .string(r.planType.rawValue),
            ]),
            "relationships": .object([
                "subscription": ref("subscriptions", r.subscriptionId),
                "subscriptionPricePoint": ref("subscriptionPricePoints", r.pricePointId),
                "territory": ref("territories", r.territory.rawValue),
            ]),
        ])])
    }

    /// I1: territory always sent. I3: paid offers need a price point, free trials must not have one.
    package static func createIntro(_ o: NewIntroOffer) throws -> JSONBody {
        var relationships: [String: JSONBody] = [
            "subscription": ref("subscriptions", o.subscriptionId),
            "territory": ref("territories", o.territory.rawValue),
        ]
        switch (o.mode, o.pricePointId) {
        case (.freeTrial, nil): break
        case (.freeTrial, .some): throw WriteBodyError.freeTrialWithPricePoint(o.territory)
        case (_, nil): throw WriteBodyError.missingPricePoint(o.territory)
        case let (_, pricePoint?): relationships["subscriptionPricePoint"] = ref("subscriptionPricePoints", pricePoint)
        }
        return .object(["data": .object([
            "type": .string("subscriptionIntroductoryOffers"),
            "attributes": .object([
                "duration": .string(o.duration.rawValue),
                "offerMode": .string(o.mode.rawValue),
                "numberOfPeriods": .int(o.numberOfPeriods),
                "startDate": date(o.startDate),
                "endDate": date(o.endDate),
                "targetSubscriptionPlanType": .string(o.planType.rawValue),
            ]),
            "relationships": .object(relationships),
        ])])
    }

    /// PATCH may change endDate only (T1-03).
    package static func endIntro(ascId: String, endDate: CalendarDate) -> JSONBody {
        .object(["data": .object([
            "type": .string("subscriptionIntroductoryOffers"),
            "id": .string(ascId),
            "attributes": .object(["endDate": .string(endDate.iso)]),
        ])])
    }

    /// Local ids "${price-1}", "${price-2}", ... in territory order; the full set every time (O6).
    static func promoPrices(_ prices: [NewPromoPrice], mode: OfferMode?) throws -> (refs: [JSONBody], included: [JSONBody]) {
        var refs: [JSONBody] = []
        var included: [JSONBody] = []
        for (index, price) in prices.sorted(by: { $0.territory < $1.territory }).enumerated() {
            if let mode {
                if mode == .freeTrial, price.pricePointId != nil { throw WriteBodyError.freeTrialWithPricePoint(price.territory) }
                if mode != .freeTrial, price.pricePointId == nil { throw WriteBodyError.missingPricePoint(price.territory) }
            }
            let localId = "${price-\(index + 1)}"
            refs.append(.object(["type": .string("subscriptionPromotionalOfferPrices"), "id": .string(localId)]))
            var relationships: [String: JSONBody] = ["territory": ref("territories", price.territory.rawValue)]
            if let pricePoint = price.pricePointId {
                relationships["subscriptionPricePoint"] = ref("subscriptionPricePoints", pricePoint)
            }
            included.append(.object([
                "type": .string("subscriptionPromotionalOfferPrices"),
                "id": .string(localId),
                "relationships": .object(relationships),
            ]))
        }
        return (refs, included)
    }

    package static func createPromo(_ o: NewPromoOffer) throws -> JSONBody {
        let prices = try promoPrices(o.prices, mode: o.mode)
        return .object([
            "data": .object([
                "type": .string("subscriptionPromotionalOffers"),
                "attributes": .object([
                    "duration": .string(o.duration.rawValue),
                    "name": .string(o.name),
                    "numberOfPeriods": .int(o.numberOfPeriods),
                    "offerCode": .string(o.offerCode),
                    "offerMode": .string(o.mode.rawValue),
                    "targetSubscriptionPlanType": .string(o.planType.rawValue),
                ]),
                "relationships": .object([
                    "subscription": ref("subscriptions", o.subscriptionId),
                    "prices": .object(["data": .array(prices.refs)]),
                ]),
            ]),
            "included": .array(prices.included),
        ])
    }

    /// The mode is not part of the payload; O4 for a re-price is guaranteed by the Planner and checked by S7.
    package static func replacePromoPrices(ascId: String, prices: [NewPromoPrice]) -> JSONBody {
        let built = (try? promoPrices(prices, mode: nil)) ?? (refs: [], included: [])
        return .object([
            "data": .object([
                "type": .string("subscriptionPromotionalOffers"),
                "id": .string(ascId),
                "relationships": .object(["prices": .object(["data": .array(built.refs)])]),
            ]),
            "included": .array(built.included),
        ])
    }

    /// L1: the whole schedule (base territory + every manual price) in one POST.
    package static func replaceIAPSchedule(_ s: NewIAPSchedule) -> JSONBody {
        var refs: [JSONBody] = []
        var included: [JSONBody] = []
        let ordered = s.manualPrices.sorted {
            ($0.territory.rawValue, $0.startDate?.iso ?? "") < ($1.territory.rawValue, $1.startDate?.iso ?? "")
        }
        for (index, price) in ordered.enumerated() {
            let localId = "${price-\(index + 1)}"
            refs.append(.object(["type": .string("inAppPurchasePrices"), "id": .string(localId)]))
            included.append(.object([
                "type": .string("inAppPurchasePrices"),
                "id": .string(localId),
                "attributes": .object(["startDate": date(price.startDate), "endDate": date(price.endDate)]),
                "relationships": .object([
                    "inAppPurchaseV2": ref("inAppPurchases", s.iapId),
                    "inAppPurchasePricePoint": ref("inAppPurchasePricePoints", price.pricePointId),
                ]),
            ]))
        }
        return .object([
            "data": .object([
                "type": .string("inAppPurchasePriceSchedules"),
                "relationships": .object([
                    "inAppPurchase": ref("inAppPurchases", s.iapId),
                    "baseTerritory": ref("territories", s.baseTerritory.rawValue),
                    "manualPrices": .object(["data": .array(refs)]),
                ]),
            ]),
            "included": .array(included),
        ])
    }

    /// Body for any payload; nil for DELETE.
    package static func body(for payload: WritePayload) throws -> JSONBody? {
        switch payload {
        case let .createRegularPrice(r): return createRegularPrice(r)
        case let .createIntro(o): return try createIntro(o)
        case let .endIntro(id, end): return endIntro(ascId: id, endDate: end)
        case let .createPromo(o): return try createPromo(o)
        case let .replacePromoPrices(id, prices): return replacePromoPrices(ascId: id, prices: prices)
        case let .replaceIAPSchedule(s): return replaceIAPSchedule(s)
        case .deleteRegularPrice, .deleteIntro, .deletePromo: return nil
        }
    }
}

package enum WritePaths {
    package static func request(for payload: WritePayload) -> (method: String, path: String) {
        switch payload {
        case .createRegularPrice: return ("POST", "/v1/subscriptionPrices")
        case let .deleteRegularPrice(id): return ("DELETE", "/v1/subscriptionPrices/\(id)")
        case .createIntro: return ("POST", "/v1/subscriptionIntroductoryOffers")
        case let .endIntro(id, _): return ("PATCH", "/v1/subscriptionIntroductoryOffers/\(id)")
        case let .deleteIntro(id): return ("DELETE", "/v1/subscriptionIntroductoryOffers/\(id)")
        case .createPromo: return ("POST", "/v1/subscriptionPromotionalOffers")
        case let .replacePromoPrices(id, _): return ("PATCH", "/v1/subscriptionPromotionalOffers/\(id)")
        case let .deletePromo(id): return ("DELETE", "/v1/subscriptionPromotionalOffers/\(id)")
        case .replaceIAPSchedule: return ("POST", "/v1/inAppPurchasePriceSchedules")
        }
    }
}
