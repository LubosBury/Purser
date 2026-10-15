#if DEBUG
import Foundation
import Domain
import Catalog

public enum SpikeVariableError: Error, Equatable, Sendable {
    case malformedLine(String)
    case unknown([String])
}

/// DEBUG only (Spike konzole): {{NAME}} variables of spike request templates, computed from the catalog snapshot, so the
/// runbooks never need real ids written down anywhere.
public enum SpikeVariables {
    /// Subscriptions of the "Purser Spike" group (product id or reference name) -> key used in variable names.
    public static let subscriptions: [(name: String, key: String, variable: String)] = [
        ("SpikeYearlyA", "YA", "SPIKE_YEARLY_A"), ("SpikeYearlyB", "YB", "SPIKE_YEARLY_B"),
        ("SpikeYearlyC", "YC", "SPIKE_YEARLY_C"), ("SpikeMonthly", "M", "SPIKE_MONTHLY"),
    ]
    /// Positions in the ascending UPFRONT price point ladder of a territory: LOW (5th), MID (15th), HIGH (25th).
    public static let ladder: [(label: String, index: Int)] = [("LOW", 4), ("MID", 14), ("HIGH", 24)]

    /// APP_ID, SPIKE_GROUP, SPIKE_YEARLY_A/B/C, SPIKE_MONTHLY, SPIKE_LIFETIME, SPIKE_SCHEDULE and per subscription key K and
    /// territory T: PP_K_T_LOW/MID/HIGH, PRICE_K_T (current row), CURPP_K_T (its price point), ABOVEPP_K_T (the next point
    /// above it), SCHED_K_T (scheduled row), INTRO_K_T (current intro, else the future one). For spike SL10n: VER_<K> and
    /// LOC_<K>_<LOCALE> with K = YA, YB, YC, M, GROUP, LIFE.
    public static func catalog(snapshot: CatalogSnapshot?, config: WorkspaceConfig, today: CalendarDate) -> [String: String] {
        var values = ["APP_ID": config.appId]
        guard let snapshot else { return values }
        let spike = snapshot.subscriptions.values.filter { $0.groupName == SpikeProbe.spikeGroupName }
        if let group = spike.first?.groupId { values["SPIKE_GROUP"] = group }
        for entry in subscriptions {
            guard let subscription = spike.first(where: { $0.productId == entry.name || $0.name == entry.name }) else { continue }
            values[entry.variable] = subscription.ascId
            for territory in snapshot.territories.keys {
                let code = territory.rawValue
                let points = snapshot.pricePoints.points(productAscId: subscription.ascId, territory: territory, planType: .upfront)
                for (label, index) in ladder where index < points.count { values["PP_\(entry.key)_\(code)_\(label)"] = points[index].id }
                if let current = snapshot.currentRegular(subscriptionId: subscription.ascId, territory: territory, planType: .upfront, on: today) {
                    values["PRICE_\(entry.key)_\(code)"] = current.ascId
                    values["CURPP_\(entry.key)_\(code)"] = current.pricePointId
                    if let index = points.firstIndex(where: { $0.id == current.pricePointId }), index + 1 < points.count {
                        values["ABOVEPP_\(entry.key)_\(code)"] = points[index + 1].id
                    }
                }
                if let scheduled = snapshot.scheduledRegular(subscriptionId: subscription.ascId, territory: territory, planType: .upfront, on: today) {
                    values["SCHED_\(entry.key)_\(code)"] = scheduled.ascId
                }
                if let intro = snapshot.currentIntro(subscriptionId: subscription.ascId, territory: territory, planType: .upfront, on: today)
                    ?? snapshot.futureIntro(subscriptionId: subscription.ascId, territory: territory, planType: .upfront, on: today) {
                    values["INTRO_\(entry.key)_\(code)"] = intro.ascId
                }
            }
        }
        if let iap = snapshot.iaps.values.first(where: { $0.productId == SpikeProbe.spikeIAPProductId }) {
            values["SPIKE_LIFETIME"] = iap.ascId
            if let scheduleId = snapshot.iapSchedules[iap.ascId]?.scheduleId { values["SPIKE_SCHEDULE"] = scheduleId }
        }
        // SL10n: VER_<K> = the version in preparation (else the live one), LOC_<K>_<LOCALE> = its localization ("en-US" -> EN_US).
        var owners: [(owner: LocalizationOwner, key: String)] = []
        for entry in subscriptions { if let id = values[entry.variable] { owners.append((LocalizationOwner.subscription(id), entry.key)) } }
        if let group = values["SPIKE_GROUP"] { owners.append((LocalizationOwner.group(group), "GROUP")) }
        if let iap = values["SPIKE_LIFETIME"] { owners.append((LocalizationOwner.iap(iap), "LIFE")) }
        for (owner, key) in owners {
            guard let version = snapshot.pendingVersion(of: owner) ?? snapshot.liveVersion(of: owner) else { continue }
            values["VER_\(key)"] = version.ascId
            for row in snapshot.metadata[owner]?.localizations ?? [] where row.versionId == version.ascId {
                values["LOC_\(key)_\(row.locale.uppercased().replacingOccurrences(of: "-", with: "_"))"] = row.ascId
            }
        }
        return values
    }

    /// "NAME=value" per line; empty lines and lines starting with "#" are skipped.
    public static func parse(_ text: String) throws -> [String: String] {
        var values: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let equals = line.firstIndex(of: "="), equals != line.startIndex else { throw SpikeVariableError.malformedLine(line) }
            values[String(line[..<equals]).trimmingCharacters(in: .whitespaces)] =
                String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        }
        return values
    }

    /// Replaces {{NAME}} and {{TODAY}}, {{TODAY+N}}, {{TODAY-N}} (UTC calendar days) in up to four passes, so a value may
    /// itself contain {{TODAY+7}}. Any {{…}} left over is an error (nothing is sent).
    public static func substitute(_ text: String, variables: [String: String], today: CalendarDate) throws -> String {
        var result = text
        for _ in 0..<4 {
            let before = result
            for (name, value) in variables { result = result.replacingOccurrences(of: "{{\(name)}}", with: value) }
            result = replaceDates(result, today: today)
            if result == before { break }
        }
        let unknown = Array(Set(matches(of: #"\{\{[A-Za-z0-9_+-]+\}\}"#, in: result))).sorted()
        guard unknown.isEmpty else { throw SpikeVariableError.unknown(unknown) }
        return result
    }

    /// Pretty-printed JSON for the console, or the raw text when the body is not JSON.
    public static func pretty(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return String(decoding: data, as: UTF8.self)
        }
        return String(decoding: pretty, as: UTF8.self)
    }

    static func replaceDates(_ text: String, today: CalendarDate) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{TODAY([+-]\d+)?\}\}"#) else { return text }
        var result = text
        while let match = regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)),
              let whole = Range(match.range, in: result) {
            let offset = Range(match.range(at: 1), in: result).flatMap { Int(result[$0]) } ?? 0
            result.replaceSubrange(whole, with: today.adding(days: offset).iso)
        }
        return result
    }

    static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }
}
#endif
