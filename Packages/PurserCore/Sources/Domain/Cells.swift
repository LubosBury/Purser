import Foundation

public enum CellKey: Hashable, Sendable, Codable, CustomStringConvertible {
    case regular(subscriptionId: String, territory: TerritoryCode, planType: PlanType)
    case intro(subscriptionId: String, territory: TerritoryCode, planType: PlanType)
    case promo(subscriptionId: String, offerCode: String)
    case iapSchedule(iapId: String)
    /// The texts of one locale of a subscription, IAP or subscription group.
    case localization(owner: LocalizationOwner, locale: String)
    /// The pending (editable or in-review) metadata version of an owner.
    case metadataVersion(owner: LocalizationOwner)

    public var storageKey: String {
        switch self {
        case let .regular(s, t, p): return "R|\(s)|\(t.rawValue)|\(p.rawValue)"
        case let .intro(s, t, p): return "I|\(s)|\(t.rawValue)|\(p.rawValue)"
        case let .promo(s, c): return "P|\(s)|\(c)"
        case let .iapSchedule(i): return "L|\(i)"
        case let .localization(o, l): return "T|\(o.kind.rawValue)|\(o.ascId)|\(l)"
        case let .metadataVersion(o): return "V|\(o.kind.rawValue)|\(o.ascId)"
        }
    }

    public init?(storageKey: String) {
        let p = storageKey.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        switch (p.first, p.count) {
        case ("R", 4):
            guard let pt = PlanType(rawValue: p[3]) else { return nil }
            self = .regular(subscriptionId: p[1], territory: TerritoryCode(p[2]), planType: pt)
        case ("I", 4):
            guard let pt = PlanType(rawValue: p[3]) else { return nil }
            self = .intro(subscriptionId: p[1], territory: TerritoryCode(p[2]), planType: pt)
        case ("P", 3): self = .promo(subscriptionId: p[1], offerCode: p[2])
        case ("L", 2): self = .iapSchedule(iapId: p[1])
        case ("T", 4):
            guard let owner = LocalizationOwner(key: "\(p[1])|\(p[2])"), !p[3].isEmpty else { return nil }
            self = .localization(owner: owner, locale: p[3])
        case ("V", 3):
            guard let owner = LocalizationOwner(key: "\(p[1])|\(p[2])") else { return nil }
            self = .metadataVersion(owner: owner)
        default: return nil
        }
    }

    public var productAscId: String {
        switch self {
        case let .regular(s, _, _), let .intro(s, _, _), let .promo(s, _): return s
        case let .iapSchedule(i): return i
        case let .localization(o, _), let .metadataVersion(o): return o.ascId
        }
    }

    public var territory: TerritoryCode? {
        switch self {
        case let .regular(_, t, _), let .intro(_, t, _): return t
        case .promo, .iapSchedule, .localization, .metadataVersion: return nil
        }
    }

    /// The owner of a text or version cell; nil for price cells.
    public var localizationOwner: LocalizationOwner? {
        switch self {
        case let .localization(o, _), let .metadataVersion(o): return o
        case .regular, .intro, .promo, .iapSchedule: return nil
        }
    }

    public var description: String { storageKey }
}

/// The state of one cell as Purser compares it ("before") or wants it ("target").
public enum CellState: Hashable, Sendable, Codable {
    case regular(current: RegularPriceRow?, scheduled: RegularPriceRow?)
    case intro(current: IntroOfferRow?, future: IntroOfferRow?)
    case promo(PromoOffer?)
    case iapSchedule(IAPSchedule?)
    /// The locale's row in the live version, its row in the pending version and that pending (editable or in-review) version.
    case localization(live: LocalizationRow?, pending: LocalizationRow?, pendingVersion: MetadataVersion?)
    /// The owner's pending (editable or in-review) version.
    case metadataVersion(MetadataVersion?)
}
