import Foundation
import Domain

/// The only implementation of ASCWriting. Called exclusively from Sources/Executor (architecture test, Task 2.10).
extension LiveASCClient: ASCWriting {
    public func createRegularPrice(_ request: NewRegularPrice) async throws -> RegularPriceRow {
        let route = WritePaths.request(for: .createRegularPrice(request))
        let document = try await http.send(method: route.method, path: route.path,
                                           body: try WriteBodies.createRegularPrice(request).data())
        return try WriteResponses.regularPriceRow(document, request: request)
    }

    public func deleteRegularPrice(ascId: String) async throws {
        try await http.delete(path: WritePaths.request(for: .deleteRegularPrice(ascId: ascId)).path)
    }

    public func createIntroductoryOffer(_ request: NewIntroOffer) async throws -> IntroOfferRow {
        let route = WritePaths.request(for: .createIntro(request))
        let document = try await http.send(method: route.method, path: route.path,
                                           body: try WriteBodies.createIntro(request).data())
        return try WriteResponses.introRow(document, request: request)
    }

    public func endIntroductoryOffer(ascId: String, endDate: CalendarDate) async throws {
        let route = WritePaths.request(for: .endIntro(ascId: ascId, endDate: endDate))
        _ = try await http.send(method: route.method, path: route.path,
                                body: try WriteBodies.endIntro(ascId: ascId, endDate: endDate).data())
    }

    public func deleteIntroductoryOffer(ascId: String) async throws {
        try await http.delete(path: WritePaths.request(for: .deleteIntro(ascId: ascId)).path)
    }

    public func createPromotionalOffer(_ request: NewPromoOffer) async throws -> PromoOffer {
        let route = WritePaths.request(for: .createPromo(request))
        let document = try await http.send(method: route.method, path: route.path,
                                           body: try WriteBodies.createPromo(request).data())
        return try WriteResponses.promoOffer(document, request: request)
    }

    public func replacePromotionalOfferPrices(ascId: String, prices: [NewPromoPrice]) async throws {
        let route = WritePaths.request(for: .replacePromoPrices(ascId: ascId, prices: prices))
        _ = try await http.send(method: route.method, path: route.path,
                                body: try WriteBodies.replacePromoPrices(ascId: ascId, prices: prices).data())
    }

    public func deletePromotionalOffer(ascId: String) async throws {
        try await http.delete(path: WritePaths.request(for: .deletePromo(ascId: ascId)).path)
    }

    public func replaceIAPPriceSchedule(_ request: NewIAPSchedule) async throws {
        let route = WritePaths.request(for: .replaceIAPSchedule(request))
        _ = try await http.send(method: route.method, path: route.path,
                                body: try WriteBodies.replaceIAPSchedule(request).data())
    }

    public func createLocalization(versionId: String, owner: LocalizationOwner, locale: String, text: LocalizationText) async throws -> LocalizationRow {
        let route = WritePaths.createLocalization(owner.kind)
        let document = try await http.send(method: route.method, path: route.path,
                                           body: try WriteBodies.createLocalization(versionId: versionId, owner: owner, locale: locale, text: text).data())
        return try WriteResponses.localizationRow(document, owner: owner, versionId: versionId, locale: locale, text: text)
    }

    public func updateLocalization(localizationId: String, owner: LocalizationOwner, text: LocalizationText) async throws {
        let route = WritePaths.updateLocalization(owner.kind, id: localizationId)
        _ = try await http.send(method: route.method, path: route.path,
                                body: try WriteBodies.updateLocalization(localizationId: localizationId, owner: owner, text: text).data())
    }

    public func createMetadataVersion(owner: LocalizationOwner) async throws -> MetadataVersion {
        let route = WritePaths.metadataVersion(owner.kind)
        let document = try await http.send(method: route.method, path: route.path,
                                           body: try WriteBodies.createMetadataVersion(owner: owner).data())
        return try WriteResponses.metadataVersion(document, owner: owner)
    }
}
