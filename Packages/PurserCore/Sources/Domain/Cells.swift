import Foundation

public enum CellKey: Hashable, Sendable, Codable, CustomStringConvertible {
    case regular(subscriptionId: String, territory: TerritoryCode, planType: PlanType)
    case intro(subscriptionId: String, territory: TerritoryCode, planType: PlanType)
    case promo(subscriptionId: String, offerCode: String)
    case iapSchedule(iapId: String)

    public var storageKey: String {
        switch self {
        case let .regular(s, t, p): return "R|\(s)|\(t.rawValue)|\(p.rawValue)"
        case let .intro(s, t, p): return "I|\(s)|\(t.rawValue)|\(p.rawValue)"
        case let .promo(s, c): return "P|\(s)|\(c)"
        case let .iapSchedule(i): return "L|\(i)"
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
        default: return nil
        }
    }

    public var productAscId: String {
        switch self {
        case let .regular(s, _, _), let .intro(s, _, _), let .promo(s, _): return s
        case let .iapSchedule(i): return i
        }
    }

    public var territory: TerritoryCode? {
        switch self {
        case let .regular(_, t, _), let .intro(_, t, _): return t
        case .promo, .iapSchedule: return nil
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
}
