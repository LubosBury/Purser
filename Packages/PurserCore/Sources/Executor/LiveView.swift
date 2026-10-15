import Foundation
import Domain
import Catalog
import ASCClient

extension CatalogSnapshot {
    package func replacing(regularRows: [RegularPriceRow]? = nil, introRows: [IntroOfferRow]? = nil,
                           promoOffers: [PromoOffer]? = nil, iapSchedules: [String: IAPSchedule]? = nil,
                           metadata: [LocalizationOwner: OwnerMetadata]? = nil) -> CatalogSnapshot {
        CatalogSnapshot(syncId: syncId, takenAt: takenAt, subscriptions: subscriptions, iaps: iaps, territories: territories,
                        regularRows: regularRows ?? self.regularRows, introRows: introRows ?? self.introRows,
                        promoOffers: promoOffers ?? self.promoOffers, iapSchedules: iapSchedules ?? self.iapSchedules,
                        pricePoints: pricePoints, offerCodesEverSeen: offerCodesEverSeen, groups: groups,
                        metadata: metadata ?? self.metadata)
    }
}

/// Rows of one product and kind read fresh from ASC.
package enum FreshRows: Sendable {
    case regular(subscriptionId: String, rows: [RegularPriceRow])
    case intro(subscriptionId: String, rows: [IntroOfferRow])
    case promo(subscriptionId: String, offers: [PromoOffer])
    case iap(iapId: String, schedule: IAPSchedule?)
    case metadata(OwnerMetadata)
}

/// The executor's freshest knowledge of live cells: the latest snapshot plus the effect of its own writes.
package struct LiveView: Sendable {
    package private(set) var snapshot: CatalogSnapshot
    private var overrides: [CellKey: CellState] = [:]

    package init(snapshot: CatalogSnapshot) { self.snapshot = snapshot }

    package func state(_ cell: CellKey, today: CalendarDate) -> CellState {
        overrides[cell] ?? snapshot.cellState(cell, on: today)
    }

    package mutating func set(_ cell: CellKey, _ state: CellState) { overrides[cell] = state }

    package mutating func replace(snapshot: CatalogSnapshot) {
        self.snapshot = snapshot
        overrides.removeAll()
    }

    package mutating func apply(_ fresh: FreshRows) {
        switch fresh {
        case let .regular(subscriptionId, rows):
            snapshot = snapshot.replacing(regularRows: snapshot.regularRows.filter { $0.subscriptionId != subscriptionId } + rows)
            overrides = overrides.filter { key, _ in
                if case let .regular(s, _, _) = key { return s != subscriptionId }
                return true
            }
        case let .intro(subscriptionId, rows):
            snapshot = snapshot.replacing(introRows: snapshot.introRows.filter { $0.subscriptionId != subscriptionId } + rows)
            overrides = overrides.filter { key, _ in
                if case let .intro(s, _, _) = key { return s != subscriptionId }
                return true
            }
        case let .promo(subscriptionId, offers):
            snapshot = snapshot.replacing(promoOffers: snapshot.promoOffers.filter { $0.subscriptionId != subscriptionId } + offers)
            overrides = overrides.filter { key, _ in
                if case let .promo(s, _) = key { return s != subscriptionId }
                return true
            }
        case let .iap(iapId, schedule):
            var schedules = snapshot.iapSchedules
            schedules[iapId] = schedule
            snapshot = snapshot.replacing(iapSchedules: schedules)
            overrides[.iapSchedule(iapId: iapId)] = nil
        case let .metadata(fresh):
            var metadata = snapshot.metadata
            metadata[fresh.owner] = fresh
            snapshot = snapshot.replacing(metadata: metadata)
            overrides = overrides.filter { key, _ in key.localizationOwner != fresh.owner }
        }
    }
}

/// Fresh read of the product and kind a cell belongs to (spec §5: required for InFlight items and after errors).
package struct CellReader: Sendable {
    let reader: any ASCReading

    package init(reader: any ASCReading) { self.reader = reader }

    package func read(_ cell: CellKey, in snapshot: CatalogSnapshot) async throws -> FreshRows {
        switch cell {
        case let .regular(subscriptionId, _, _):
            return .regular(subscriptionId: subscriptionId, rows: try await reader.regularPrices(subscription: try info(subscriptionId, snapshot)))
        case let .intro(subscriptionId, _, _):
            return .intro(subscriptionId: subscriptionId, rows: try await reader.introductoryOffers(subscription: try info(subscriptionId, snapshot)))
        case let .promo(subscriptionId, _):
            return .promo(subscriptionId: subscriptionId, offers: try await reader.promotionalOffers(subscription: try info(subscriptionId, snapshot)))
        case let .iapSchedule(iapId):
            return .iap(iapId: iapId, schedule: try await reader.iapPriceSchedule(iapId: iapId))
        case let .localization(owner, _), let .metadataVersion(owner):
            return .metadata(try await reader.metadata(owner: owner))
        }
    }

    func info(_ id: String, _ snapshot: CatalogSnapshot) throws -> SubscriptionInfo {
        guard let info = snapshot.subscriptions[id] else { throw ExecutorError.unknownProduct(id) }
        return info
    }
}
