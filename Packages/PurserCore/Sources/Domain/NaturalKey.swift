import CryptoKit
import Foundation

/// Natural keys from spec §5 "Idempotence". Pure and stable across releases: they are persisted.
public enum NaturalKey {
    public static func of(_ payload: WritePayload) -> String {
        switch payload {
        case let .createRegularPrice(p):
            return "R+|\(p.subscriptionId)|\(p.territory)|\(p.planType.rawValue)|\(p.startDate?.iso ?? "-")|\(p.pricePointId)|\(p.preserveCurrentPrice)"
        case let .deleteRegularPrice(id): return "R-|\(id)"
        case let .createIntro(o):
            return "I+|\(o.subscriptionId)|\(o.territory)|\(o.planType.rawValue)|\(o.mode.rawValue)|\(o.duration.rawValue)|\(o.pricePointId ?? "-")|\(o.startDate?.iso ?? "-")"
        case let .endIntro(id, end): return "I~|\(id)|\(end.iso)"
        case let .deleteIntro(id): return "I-|\(id)"
        case let .createPromo(o): return "P+|\(o.subscriptionId)|\(o.offerCode)"
        case let .replacePromoPrices(id, prices): return "P~|\(id)|\(hash(prices.sorted { $0.territory < $1.territory }.map { "\($0.territory):\($0.pricePointId ?? "-")" }))"
        case let .deletePromo(id): return "P-|\(id)"
        case let .replaceIAPSchedule(s):
            return "L~|\(s.iapId)|\(hash([s.baseTerritory.rawValue] + s.manualPrices.map { "\($0.territory):\($0.pricePointId):\($0.startDate?.iso ?? "-"):\($0.endDate?.iso ?? "-")" }))"
        case let .setLocalization(s):
            return "T=|\(s.owner.key)|\(s.locale)|\(hash([s.text.name, s.text.description ?? "-", s.text.customAppName ?? "-"]))"
        case let .createMetadataVersion(owner):
            return "V+|\(owner.key)"
        }
    }

    static func hash(_ parts: [String]) -> String {
        SHA256.hash(data: Data(parts.joined(separator: ";").utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
