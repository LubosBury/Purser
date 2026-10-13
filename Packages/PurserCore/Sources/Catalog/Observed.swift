import CryptoKit
import Foundation
import GRDB
import Domain
import Store

/// One row read from ASC in its domain shape, ready to be stored as an observation.
struct Observed: Sendable {
    enum Row: Sendable {
        case price(RegularPriceRow)
        case intro(IntroOfferRow)
        case promo(PromoOffer)
        case schedule(IAPSchedule)
    }

    let ascId: String
    let cell: CellKey
    let rawJSON: String
    let row: Row

    init(_ row: Row) throws {
        self.row = row
        switch row {
        case let .price(value):
            ascId = value.ascId
            cell = .regular(subscriptionId: value.subscriptionId, territory: value.territory, planType: value.planType)
            rawJSON = try JSONCoding.string(value)
        case let .intro(value):
            ascId = value.ascId
            cell = .intro(subscriptionId: value.subscriptionId, territory: value.territory, planType: value.planType)
            rawJSON = try JSONCoding.string(value)
        case let .promo(value):
            ascId = value.ascId
            cell = .promo(subscriptionId: value.subscriptionId, offerCode: value.offerCode)
            rawJSON = try JSONCoding.string(value)
        case let .schedule(value):
            ascId = value.iapId
            cell = .iapSchedule(iapId: value.iapId)
            rawJSON = try JSONCoding.string(value)
        }
    }

    static func decode(kind: String, rawJSON: String) throws -> Row {
        switch kind {
        case ObservationKind.price: return .price(try JSONCoding.decode(RegularPriceRow.self, from: rawJSON))
        case ObservationKind.intro: return .intro(try JSONCoding.decode(IntroOfferRow.self, from: rawJSON))
        case ObservationKind.promo: return .promo(try JSONCoding.decode(PromoOffer.self, from: rawJSON))
        case ObservationKind.iapSchedule: return .schedule(try JSONCoding.decode(IAPSchedule.self, from: rawJSON))
        default: throw StoreError.corruptValue(table: "observation", column: "kind", value: kind)
        }
    }

    static func contentHash(_ rawJSON: String) -> String {
        SHA256.hash(data: Data(rawJSON.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Czech label used in finding messages.
    static func label(kind: String) -> String {
        switch kind {
        case ObservationKind.price: return "Regular price row"
        case ObservationKind.intro: return "Intro offer"
        case ObservationKind.promo: return "Promo offer"
        default: return "IAP price schedule"
        }
    }
}

/// Items Purser wrote (or may have written), used to tell PURSER rows from EXTERNAL ones.
struct PurserItems: Sendable {
    static let writtenStates: [ItemState] = [.inFlight, .done, .mismatch, .effective]

    var naturalKeys: Set<String> = []
    var ascIds: Set<String> = []

    static func load(_ db: Database) throws -> PurserItems {
        let states = writtenStates.map { "'\($0.rawValue)'" }.joined(separator: ", ")
        var items = PurserItems()
        for row in try GRDB.Row.fetchAll(db, sql: "SELECT natural_key, asc_id FROM item WHERE state IN (\(states))") {
            items.naturalKeys.insert(row["natural_key"])
            if let ascId: String = row["asc_id"] { items.ascIds.insert(ascId) }
        }
        return items
    }

    /// The row was created or changed by a Purser item: same asc id, or the natural key of a create/end/reprice/replace.
    func explainsAppearance(_ observed: Observed) -> Bool {
        if ascIds.contains(observed.ascId) { return true }
        return Self.appearanceKeys(observed.row).contains { naturalKeys.contains($0) }
    }

    /// The row was removed by a Purser DELETE item.
    func explainsRemoval(_ row: Observed.Row) -> Bool {
        switch row {
        case let .price(value): return naturalKeys.contains(NaturalKey.of(.deleteRegularPrice(ascId: value.ascId)))
        case let .intro(value): return naturalKeys.contains(NaturalKey.of(.deleteIntro(ascId: value.ascId)))
        case let .promo(value): return naturalKeys.contains(NaturalKey.of(.deletePromo(ascId: value.ascId)))
        case .schedule: return false
        }
    }

    static func appearanceKeys(_ row: Observed.Row) -> [String] {
        switch row {
        case let .price(value):
            return [true, false].map { preserve in
                NaturalKey.of(.createRegularPrice(NewRegularPrice(
                    subscriptionId: value.subscriptionId, territory: value.territory, planType: value.planType,
                    pricePointId: value.pricePointId, startDate: value.startDate, preserveCurrentPrice: preserve)))
            }
        case let .intro(value):
            var keys = [NaturalKey.of(.createIntro(NewIntroOffer(
                subscriptionId: value.subscriptionId, territory: value.territory, planType: value.planType, mode: value.mode,
                duration: value.duration, numberOfPeriods: value.numberOfPeriods, startDate: value.startDate,
                endDate: value.endDate, pricePointId: value.pricePointId)))]
            if let end = value.endDate { keys.append(NaturalKey.of(.endIntro(ascId: value.ascId, endDate: end))) }
            return keys
        case let .promo(value):
            return [
                NaturalKey.of(.createPromo(NewPromoOffer(
                    subscriptionId: value.subscriptionId, offerCode: value.offerCode, name: value.name, mode: value.mode,
                    duration: value.duration, numberOfPeriods: value.numberOfPeriods, planType: value.planType, prices: []))),
                NaturalKey.of(.replacePromoPrices(ascId: value.ascId, prices: value.prices.map {
                    NewPromoPrice(territory: $0.territory, pricePointId: $0.pricePointId)
                })),
            ]
        case let .schedule(value):
            return [NaturalKey.of(.replaceIAPSchedule(NewIAPSchedule(
                iapId: value.iapId, baseTerritory: value.baseTerritory,
                manualPrices: value.manualPrices.map {
                    NewIAPManualPrice(territory: $0.territory, pricePointId: $0.pricePointId, startDate: $0.startDate, endDate: $0.endDate)
                })))]
        }
    }
}
