import Foundation

/// Where a product is sold: the availability of a subscription or an in-app purchase. A clone copies it.
public struct ProductAvailability: Hashable, Sendable, Codable {
    public var territories: Set<TerritoryCode>
    public var availableInNewTerritories: Bool

    public init(territories: Set<TerritoryCode>, availableInNewTerritories: Bool) {
        self.territories = territories
        self.availableInNewTerritories = availableInNewTerritories
    }
}

/// The App Store review screenshot of a subscription or an in-app purchase. It is not versioned: it stays on the product.
public struct ReviewScreenshot: Hashable, Sendable, Codable {
    public var ascId: String
    public var fileName: String
    public var fileSize: Int
    public var templateURL: String?   // imageAsset.templateUrl with {w}, {h}, {f}
    public var width: Int?
    public var height: Int?
    public var deliveryState: String? // assetDeliveryState.state

    public init(ascId: String, fileName: String, fileSize: Int, templateURL: String?, width: Int?, height: Int?, deliveryState: String?) {
        self.ascId = ascId; self.fileName = fileName; self.fileSize = fileSize; self.templateURL = templateURL
        self.width = width; self.height = height; self.deliveryState = deliveryState
    }

    /// assetDeliveryState values after the commit (`PATCH uploaded=true`).
    public static let committedStates: Set<String> = ["UPLOAD_COMPLETE", "COMPLETE"]

    /// The upload ended with a commit. AWAITING_UPLOAD (a reservation without a commit), FAILED and unknown states did
    /// not; a clone run deletes such a screenshot and uploads it again.
    public var isCommitted: Bool { deliveryState.map { Self.committedStates.contains($0) } ?? false }

    /// A finished image that can be downloaded: COMPLETE, with a template URL and a size.
    public var isDownloadable: Bool { deliveryState == "COMPLETE" && templateURL != nil && width != nil && height != nil }
}
