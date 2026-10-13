import Foundation

public enum PlanType: String, Codable, Sendable, CaseIterable { case upfront = "UPFRONT", monthly = "MONTHLY" }

public enum OfferMode: String, Codable, Sendable, CaseIterable {
    case freeTrial = "FREE_TRIAL", payUpFront = "PAY_UP_FRONT", payAsYouGo = "PAY_AS_YOU_GO"
}

public enum OfferDuration: String, Codable, Sendable, CaseIterable {
    case threeDays = "THREE_DAYS", oneWeek = "ONE_WEEK", twoWeeks = "TWO_WEEKS", oneMonth = "ONE_MONTH",
         twoMonths = "TWO_MONTHS", threeMonths = "THREE_MONTHS", sixMonths = "SIX_MONTHS", oneYear = "ONE_YEAR"
}

public enum SubscriptionPeriod: String, Codable, Sendable, CaseIterable {
    case oneWeek = "ONE_WEEK", oneMonth = "ONE_MONTH", twoMonths = "TWO_MONTHS",
         threeMonths = "THREE_MONTHS", sixMonths = "SIX_MONTHS", oneYear = "ONE_YEAR"
}

public enum ProductKind: String, Codable, Sendable { case subscription = "SUB", iap = "IAP" }

public enum KeyKind: String, Codable, Sendable { case team, individual }

public struct ProductState: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws { self.init(try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    public var description: String { rawValue }

    public static let approved = ProductState("APPROVED")
    public static let readyToSubmit = ProductState("READY_TO_SUBMIT")
    public static let missingMetadata = ProductState("MISSING_METADATA")
    public static let developerActionNeeded = ProductState("DEVELOPER_ACTION_NEEDED")
    public static let waitingForReview = ProductState("WAITING_FOR_REVIEW")
    public static let inReview = ProductState("IN_REVIEW")
    /// Rule A5: the only states in which Purser writes.
    public static let writable: Set<ProductState> = [.approved, .readyToSubmit, .missingMetadata, .developerActionNeeded]
}
