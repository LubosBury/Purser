import Foundation
import Synchronization
import Domain
import ASCClient

/// Thread-safe box for values recorded from @Sendable closures.
public final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>
    public init(_ value: Value) { mutex = Mutex(value) }
    public func update(_ body: (inout Value) -> Void) { mutex.withLock { body(&$0) } }
    public var value: Value { mutex.withLock { $0 } }
}

/// Calls `probe` right before forwarding each write, to observe the database at the moment of sending.
public struct ProbeWriter: ASCWriting {
    let inner: any ASCWriting
    let probe: @Sendable () -> Void
    public init(inner: any ASCWriting, probe: @escaping @Sendable () -> Void) { self.inner = inner; self.probe = probe }
    public func createRegularPrice(_ r: NewRegularPrice) async throws -> RegularPriceRow { probe(); return try await inner.createRegularPrice(r) }
    public func deleteRegularPrice(ascId: String) async throws { probe(); try await inner.deleteRegularPrice(ascId: ascId) }
    public func createIntroductoryOffer(_ r: NewIntroOffer) async throws -> IntroOfferRow { probe(); return try await inner.createIntroductoryOffer(r) }
    public func endIntroductoryOffer(ascId: String, endDate: CalendarDate) async throws { probe(); try await inner.endIntroductoryOffer(ascId: ascId, endDate: endDate) }
    public func deleteIntroductoryOffer(ascId: String) async throws { probe(); try await inner.deleteIntroductoryOffer(ascId: ascId) }
    public func createPromotionalOffer(_ r: NewPromoOffer) async throws -> PromoOffer { probe(); return try await inner.createPromotionalOffer(r) }
    public func replacePromotionalOfferPrices(ascId: String, prices: [NewPromoPrice]) async throws { probe(); try await inner.replacePromotionalOfferPrices(ascId: ascId, prices: prices) }
    public func deletePromotionalOffer(ascId: String) async throws { probe(); try await inner.deletePromotionalOffer(ascId: ascId) }
    public func replaceIAPPriceSchedule(_ r: NewIAPSchedule) async throws { probe(); try await inner.replaceIAPPriceSchedule(r) }
    public func createLocalization(versionId: String, owner: LocalizationOwner, locale: String, text: LocalizationText) async throws -> LocalizationRow {
        probe(); return try await inner.createLocalization(versionId: versionId, owner: owner, locale: locale, text: text)
    }
    public func updateLocalization(localizationId: String, owner: LocalizationOwner, text: LocalizationText) async throws {
        probe(); try await inner.updateLocalization(localizationId: localizationId, owner: owner, text: text)
    }
    public func createMetadataVersion(owner: LocalizationOwner) async throws -> MetadataVersion {
        probe(); return try await inner.createMetadataVersion(owner: owner)
    }
}

/// Reports success without touching ASC, so verify never finds the target (Mismatch tests).
public struct GhostWriter: ASCWriting {
    public init() {}
    public func createRegularPrice(_ r: NewRegularPrice) async throws -> RegularPriceRow {
        RegularPriceRow(ascId: "ghost-price", subscriptionId: r.subscriptionId, territory: r.territory, planType: r.planType,
                        rawPlanType: r.planType.rawValue, startDate: r.startDate, preserved: r.preserveCurrentPrice,
                        pricePointId: r.pricePointId, customerPrice: 0)
    }
    public func deleteRegularPrice(ascId: String) async throws {}
    public func createIntroductoryOffer(_ r: NewIntroOffer) async throws -> IntroOfferRow {
        IntroOfferRow(ascId: "ghost-intro", subscriptionId: r.subscriptionId, territory: r.territory, planType: r.planType,
                      rawPlanType: r.planType.rawValue, mode: r.mode, duration: r.duration, numberOfPeriods: r.numberOfPeriods,
                      startDate: r.startDate, endDate: r.endDate, pricePointId: r.pricePointId, customerPrice: nil)
    }
    public func endIntroductoryOffer(ascId: String, endDate: CalendarDate) async throws {}
    public func deleteIntroductoryOffer(ascId: String) async throws {}
    public func createPromotionalOffer(_ r: NewPromoOffer) async throws -> PromoOffer {
        PromoOffer(ascId: "ghost-promo", subscriptionId: r.subscriptionId, offerCode: r.offerCode, name: r.name, mode: r.mode,
                   duration: r.duration, numberOfPeriods: r.numberOfPeriods, planType: r.planType, prices: [])
    }
    public func replacePromotionalOfferPrices(ascId: String, prices: [NewPromoPrice]) async throws {}
    public func deletePromotionalOffer(ascId: String) async throws {}
    public func replaceIAPPriceSchedule(_ r: NewIAPSchedule) async throws {}
    public func createLocalization(versionId: String, owner: LocalizationOwner, locale: String, text: LocalizationText) async throws -> LocalizationRow {
        LocalizationRow(ascId: "ghost-localization", owner: owner, versionId: versionId, locale: locale, text: text)
    }
    public func updateLocalization(localizationId: String, owner: LocalizationOwner, text: LocalizationText) async throws {}
    public func createMetadataVersion(owner: LocalizationOwner) async throws -> MetadataVersion {
        MetadataVersion(ascId: "ghost-version", owner: owner, number: 0, state: .prepareForSubmission)
    }
}
