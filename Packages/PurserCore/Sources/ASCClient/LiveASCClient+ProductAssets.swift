import Foundation
import Domain

/// Reads a clone needs besides the catalog: availability with `availableInNewTerritories` and the review screenshot.
extension LiveASCClient {
    public func subscriptionAvailability(subscriptionId: String) async throws -> ProductAvailability? {
        try await availability(at: ASCPath.subscriptionAvailability(subscriptionId)) { ASCPath.availableTerritories(availability: $0) }
    }

    public func iapAvailability(iapId: String) async throws -> ProductAvailability? {
        try await availability(at: ASCPath.iapAvailability(iapId)) { ASCPath.iapAvailableTerritories(availability: $0) }
    }

    public func reviewScreenshot(of owner: LocalizationOwner) async throws -> ReviewScreenshot? {
        let path: String
        switch owner.kind {
        case .subscription: path = ASCPath.subscriptionReviewScreenshot(owner.ascId)
        case .iap: path = ASCPath.iapReviewScreenshot(owner.ascId)
        case .group: return nil
        }
        let document: JSONAPIDocument
        do {
            document = try await http.get(path, query: [])
        } catch ASCError.http(status: 404, code: _, title: _, detail: _) {
            return nil
        }
        guard let screenshot = ASCMapping.reviewScreenshot(document) else { return nil }
        await http.appGuard.allowChildren([screenshot.ascId])
        return screenshot
    }

    /// GET of the availability, then its territories; nil when the product has none (404 or no resource).
    private func availability(at path: String, territories: (String) -> String) async throws -> ProductAvailability? {
        let document: JSONAPIDocument
        do {
            document = try await http.get(path, query: [])
        } catch ASCError.http(status: 404, code: _, title: _, detail: _) {
            return nil
        }
        guard let resource = document.data.first else { return nil }
        await http.appGuard.allowChildren([resource.id])
        let pages = try await http.getAll(territories(resource.id), query: [URLQueryItem(name: "limit", value: "200")])
        return ProductAvailability(territories: Set(pages.flatMap(\.data).map { TerritoryCode($0.id) }),
                                   availableInNewTerritories: resource.bool("availableInNewTerritories") ?? false)
    }
}

extension ASCMapping {
    /// The screenshot of GET …/appStoreReviewScreenshot (or of a reservation); nil for `data: null`.
    static func reviewScreenshot(_ document: JSONAPIDocument) -> ReviewScreenshot? {
        guard let resource = document.data.first else { return nil }
        let asset = attributeObject(resource.attributes["imageAsset"])
        let delivery = attributeObject(resource.attributes["assetDeliveryState"])
        return ReviewScreenshot(ascId: resource.id, fileName: resource.string("fileName") ?? "", fileSize: resource.int("fileSize") ?? 0,
                                templateURL: asset?["templateUrl"]?.stringValue, width: asset?["width"]?.intValue,
                                height: asset?["height"]?.intValue, deliveryState: delivery?["state"]?.stringValue)
    }

    static func attributeObject(_ value: JSONValue?) -> [String: JSONValue]? {
        if case let .object(members)? = value { return members }
        return nil
    }
}
