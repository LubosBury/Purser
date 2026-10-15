import Foundation

// Cloning products for A/B tests (spec "Localizations and cloning" §6). The request lives in Domain so that the Planner
// (CloneDrafts) and the Executor (ProductCreator) share it; the steps and the report are in the Executor.

/// One product to clone, a subscription or an in-app purchase, with the Product ID and reference name of its clone.
public struct CloneItem: Hashable, Sendable, Codable {
    public var source: LocalizationOwner       // .subscription or .iap
    public var productId: String
    public var name: String                     // reference name

    public init(source: LocalizationOwner, productId: String, name: String) {
        self.source = source; self.productId = productId; self.name = name
    }
}

/// Where subscription clones go: each to its source's group, or all to one new group with the texts of the source group.
public enum CloneGroupTarget: Hashable, Sendable, Codable { case sourceGroup, newGroup(name: String) }

/// The level of a subscription clone: the source's (variants of an A/B test) or a new level at the end of the group.
public enum CloneLevel: String, Hashable, Sendable, Codable { case sameAsSource, end }

/// What a clone copies besides the product, its attributes and its availability. Prices and offers become Draft plans.
public struct CloneCopy: Hashable, Sendable, Codable {
    public var localizations: Bool
    public var reviewScreenshot: Bool
    public var prices: Bool
    public var introOffers: Bool
    public var promoOffers: Bool

    public init(localizations: Bool = true, reviewScreenshot: Bool = true, prices: Bool = true, introOffers: Bool = true,
                promoOffers: Bool = true) {
        self.localizations = localizations; self.reviewScreenshot = reviewScreenshot; self.prices = prices
        self.introOffers = introOffers; self.promoOffers = promoOffers
    }
}

public struct CloneRequest: Hashable, Sendable, Codable {
    public var items: [CloneItem]
    public var group: CloneGroupTarget
    public var level: CloneLevel
    public var copy: CloneCopy
    /// Appended to the codes of copied promotional offers; the sheet also proposes Product IDs and names with it.
    public var offerCodeSuffix: String

    public init(items: [CloneItem], group: CloneGroupTarget, level: CloneLevel, copy: CloneCopy, offerCodeSuffix: String) {
        self.items = items; self.group = group; self.level = level; self.copy = copy; self.offerCodeSuffix = offerCodeSuffix
    }
}
