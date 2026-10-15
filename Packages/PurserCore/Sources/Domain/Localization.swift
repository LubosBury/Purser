import Foundation

/// Who owns localized metadata in App Store Connect.
public enum LocalizationOwnerKind: String, Codable, Sendable, CaseIterable, Comparable {
    case subscription = "S", iap = "I", group = "G"
    public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
}

public struct LocalizationOwner: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public var kind: LocalizationOwnerKind
    public var ascId: String
    public init(_ kind: LocalizationOwnerKind, _ ascId: String) { self.kind = kind; self.ascId = ascId }
    public static func subscription(_ ascId: String) -> Self { Self(.subscription, ascId) }
    public static func iap(_ ascId: String) -> Self { Self(.iap, ascId) }
    public static func group(_ ascId: String) -> Self { Self(.group, ascId) }
    /// "S|123", used inside cell storage keys and the metadata_version table.
    public var key: String { "\(kind.rawValue)|\(ascId)" }
    public init?(key: String) {
        let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let kind = LocalizationOwnerKind(rawValue: parts[0]), !parts[1].isEmpty else { return nil }
        self.init(kind, parts[1])
    }
    public static func < (l: Self, r: Self) -> Bool { (l.kind, l.ascId) < (r.kind, r.ascId) }
    public var description: String { key }
}

/// State of a subscription, IAP or group version (ASC API 4.4.1). Unknown values are kept and treated as locked.
public struct MetadataVersionState: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws { self.init(try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    public var description: String { rawValue }

    public static let prepareForSubmission = Self("PREPARE_FOR_SUBMISSION")
    public static let readyForReview = Self("READY_FOR_REVIEW")
    public static let waitingForReview = Self("WAITING_FOR_REVIEW")
    public static let inReview = Self("IN_REVIEW")
    public static let accepted = Self("ACCEPTED")
    public static let approved = Self("APPROVED")
    public static let replacedWithNewVersion = Self("REPLACED_WITH_NEW_VERSION")
    public static let rejected = Self("REJECTED")
    public static let developerRejected = Self("DEVELOPER_REJECTED")

    public enum Role: String, Sendable, Codable { case live, editable, inReview, retired }

    /// Spec §4 "Version roles". Any state Purser does not know counts as in review: never written.
    public var role: Role {
        switch self {
        case .approved, .accepted: return .live
        case .prepareForSubmission, .readyForReview, .rejected, .developerRejected: return .editable
        case .replacedWithNewVersion: return .retired
        default: return .inReview
        }
    }
}

public struct MetadataVersion: Hashable, Sendable, Codable {
    public var ascId: String              // "" = created by the plan (K9 placeholder convention)
    public var owner: LocalizationOwner
    public var number: Int
    public var state: MetadataVersionState
    public init(ascId: String, owner: LocalizationOwner, number: Int, state: MetadataVersionState) {
        self.ascId = ascId; self.owner = owner; self.number = number; self.state = state
    }
}

/// The customer-facing texts of one locale. `description` is unused for groups, `customAppName` only for groups.
public struct LocalizationText: Hashable, Sendable, Codable {
    public var name: String
    public var description: String?
    public var customAppName: String?
    public init(name: String, description: String? = nil, customAppName: String? = nil) {
        self.name = name; self.description = description; self.customAppName = customAppName
    }
}

public struct LocalizationRow: Hashable, Sendable, Codable {
    public var ascId: String              // "" = created by the plan
    public var owner: LocalizationOwner
    public var versionId: String          // "" = in a version the plan creates
    public var locale: String
    public var text: LocalizationText
    public init(ascId: String, owner: LocalizationOwner, versionId: String, locale: String, text: LocalizationText) {
        self.ascId = ascId; self.owner = owner; self.versionId = versionId; self.locale = locale; self.text = text
    }
}

/// Everything one versions read returns for an owner: every version and the localizations of the live and pending ones.
public struct OwnerMetadata: Hashable, Sendable, Codable {
    public var owner: LocalizationOwner
    public var versions: [MetadataVersion]       // sorted by number
    public var localizations: [LocalizationRow]  // sorted by (versionId, locale)
    public init(owner: LocalizationOwner, versions: [MetadataVersion], localizations: [LocalizationRow]) {
        self.owner = owner
        self.versions = versions.sorted { $0.number < $1.number }
        self.localizations = localizations.sorted { ($0.versionId, $0.locale) < ($1.versionId, $1.locale) }
    }
    /// Highest number with role .live.
    public var liveVersion: MetadataVersion? { versions.last { $0.state.role == .live } }
    /// Highest number with role .editable or .inReview, newer than the live version.
    public var pendingVersion: MetadataVersion? {
        let liveNumber = liveVersion?.number ?? 0
        return versions.last { ($0.state.role == .editable || $0.state.role == .inReview) && $0.number > liveNumber }
    }

    /// The localization cell of `locale`: the row of the live version, the row of the pending version and that version.
    /// The one implementation behind CatalogSnapshot.cellState.
    public func localizationCell(locale: String) -> CellState {
        func row(_ version: MetadataVersion?) -> LocalizationRow? {
            version.flatMap { version in localizations.first { $0.versionId == version.ascId && $0.locale == locale } }
        }
        let pending = pendingVersion
        return .localization(live: row(liveVersion), pending: row(pending), pendingVersion: pending)
    }
}

public struct SubscriptionGroupInfo: Hashable, Sendable, Codable {
    public var ascId: String
    public var referenceName: String
    public init(ascId: String, referenceName: String) { self.ascId = ascId; self.referenceName = referenceName }
}
