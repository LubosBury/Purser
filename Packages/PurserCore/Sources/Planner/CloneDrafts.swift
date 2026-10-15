import Foundation
import Domain
import Catalog

/// What preparing the price drafts of a clone gave: one line per draft (its plan id, or why it was not built), what the
/// drafts leave out, or why nothing was prepared (the sync after the clone did not bring the clones in).
public struct CloneDraftOutcome: Hashable, Sendable {
    public struct Line: Hashable, Sendable {
        public var title: String
        public var planId: String?
        public var error: String?
        /// Set for a draft that was not built because a plan with its title already exists (`planId` is that plan).
        public var note: String?
        public init(title: String, planId: String?, error: String?, note: String? = nil) {
            self.title = title; self.planId = planId; self.error = error; self.note = note
        }
    }

    public var drafts: [Line]
    public var notes: [String]
    public var syncProblem: String?

    public init(drafts: [Line] = [], notes: [String] = [], syncProblem: String? = nil) {
        self.drafts = drafts; self.notes = notes; self.syncProblem = syncProblem
    }
}

/// The Draft plans that give clones the current prices and offers of their sources (spec "Localizations and cloning" §6).
/// Ordinary specs for the existing builders, planned against a catalog that already holds the clones: a price snaps to
/// the clone's point of the same price (the same tier), offer codes get the suffix. A cell the clone already has is left
/// out, so preparing the drafts again after some were applied adds only what is missing. The order is the order to apply
/// them: regular prices first (rule I8 blocks a first regular price under a paid intro), then intro offers, promotional
/// offers and in-app purchase prices. UPFRONT plan types only; `notCopied` names the rest and everything a draft had to
/// leave out (a territory the clone is not available in, an offer without a price, a code that cannot be used).
public enum CloneDrafts {
    public static func specs(created: [String: String], copy: CloneCopy, offerCodeSuffix: String, snapshot: CatalogSnapshot,
                             today: CalendarDate) -> [(title: String, spec: PlanSpec)] {
        let built = build(created: created, copy: copy, offerCodeSuffix: offerCodeSuffix, snapshot: snapshot, today: today)
        return built.regular + built.intro + built.promo + built.iap
    }

    /// What the drafts leave out, in words for the sheet and the MCP answer. The suffix is needed to tell which promotional
    /// offers cannot be copied under their new codes.
    public static func notCopied(created: [String: String], copy: CloneCopy, offerCodeSuffix: String, snapshot: CatalogSnapshot,
                                 today: CalendarDate) -> [String] {
        build(created: created, copy: copy, offerCodeSuffix: offerCodeSuffix, snapshot: snapshot, today: today).notes
    }

    /// Whether a code passes the length and character checks of `OfferCodeAdvisor`. Whether the code was used before is
    /// not asked here: rule O1 judges that when the draft is planned. One definition for the request check of a clone
    /// (before anything is written) and for the drafts.
    public static func isUsableOfferCode(_ code: String) -> Bool {
        !OfferCodeAdvisor(registry: []).check(code).problems.contains {
            switch $0 {
            case .tooLong, .invalidCharacters, .empty: return true
            case .usedBefore, .caseVariantOf: return false
            }
        }
    }

    typealias Draft = (title: String, spec: PlanSpec)

    struct Built {
        var regular: [Draft] = []
        var intro: [Draft] = []
        var promo: [Draft] = []
        var iap: [Draft] = []
        var notes: [String] = []
    }

    /// The drafts and the notes of one pass over the sources, so that both answers always agree.
    static func build(created: [String: String], copy: CloneCopy, offerCodeSuffix: String, snapshot: CatalogSnapshot,
                      today: CalendarDate) -> Built {
        var built = Built()
        // Promotional offer codes the clones get in this pass (suffixed code -> the source product that gives it). Two sources
        // may carry the same code; their clones would carry the same suffixed code, and a code can be used only once. The
        // source with the lower asc id keeps it, the other offer is not drafted and a note says so.
        var claimedCodes: [String: String] = [:]
        for (sourceId, cloneId) in created.sorted(by: { $0.key < $1.key }) {
            if let source = snapshot.subscriptions[sourceId] {
                guard let clone = snapshot.subscriptions[cloneId] else {
                    built.notes.append("The clone of \(source.productId) is not in the catalog yet; sync and prepare the drafts again.")
                    continue
                }
                subscriptionDrafts(source, clone, copy: copy, suffix: offerCodeSuffix, snapshot, today, claimedCodes: &claimedCodes, into: &built)
            } else if let source = snapshot.iaps[sourceId] {
                guard let clone = snapshot.iaps[cloneId] else {
                    built.notes.append("The clone of \(source.productId) is not in the catalog yet; sync and prepare the drafts again.")
                    continue
                }
                if copy.prices {
                    if let spec = iapSpec(source, clone, snapshot, today) {
                        built.iap.append(("Clone \(clone.productId) of \(source.productId): prices", spec))
                    }
                    if let schedule = snapshot.iapSchedules[sourceId],
                       let first = schedule.manualPrices.compactMap(\.startDate).filter({ $0 > today }).min() {
                        built.notes.append("The future prices of \(source.productId) (from \(first.iso)) are not copied; plan them for the clone once its first prices are applied.")
                    }
                }
            }
        }
        return built
    }

    static func subscriptionDrafts(_ source: SubscriptionInfo, _ clone: SubscriptionInfo, copy: CloneCopy, suffix: String,
                                   _ snapshot: CatalogSnapshot, _ today: CalendarDate, claimedCodes: inout [String: String],
                                   into built: inout Built) {
        let prefix = "Clone \(clone.productId) of \(source.productId): "
        let shared = source.availableTerritories.intersection(clone.availableTerritories)
        if shared.isEmpty, copy.prices || copy.introOffers || copy.promoOffers {
            built.notes.append("No territory is available for both \(source.productId) and its clone, so no prices or offers are drafted for the clone; check the clone's availability.")
        }
        if copy.prices {
            if let spec = regularSpec(source, clone, snapshot, today) {
                built.regular.append((prefix + "regular prices (apply first)", spec))
            }
            let lost = lostTerritories(source, shared: shared, snapshot, today)
            if !shared.isEmpty, !lost.isEmpty {
                built.notes.append(lost.count == 1
                    ? "1 territory where \(source.productId) has a price is not available for the clone; its price there is not copied."
                    : "\(lost.count) territories where \(source.productId) has a price are not available for the clone; their prices are not copied.")
            }
            if source.availableTerritories.contains(where: { snapshot.currentRegular(subscriptionId: source.ascId, territory: $0, planType: .monthly, on: today) != nil }) {
                built.notes.append("The MONTHLY prices of \(source.productId) are not copied; Purser writes UPFRONT prices only.")
            }
            let changes = source.availableTerritories.compactMap {
                snapshot.scheduledRegular(subscriptionId: source.ascId, territory: $0, planType: .upfront, on: today)?.startDate
            }
            if let first = changes.min() {
                built.notes.append("The scheduled price changes of \(source.productId) (from \(first.iso)) are not copied; plan them for the clone once its first prices are applied.")
            }
        }
        if copy.introOffers {
            let intros = introSpecs(source, clone, shared: shared, snapshot, today)
            built.intro += intros.drafts.map { (prefix + "intro " + $0.text, $0.spec) }
            built.notes += intros.notes
            if snapshot.introRows.contains(where: {
                $0.subscriptionId == source.ascId && $0.planType == .monthly && ($0.endDate.map { $0 > today } ?? true)
            }) {
                built.notes.append("The introductory offers of \(source.productId) for the MONTHLY plan type are not copied.")
            }
        }
        if copy.promoOffers {
            let promos = promoSpecs(source, clone, suffix: suffix, snapshot, claimedCodes: &claimedCodes)
            built.promo += promos.drafts.map { (prefix + "promotional offer " + $0.code, $0.spec) }
            built.notes += promos.notes
            if snapshot.promoOffers(subscriptionId: source.ascId).contains(where: { $0.planType == .monthly }) {
                built.notes.append("The promotional offers of \(source.productId) for the MONTHLY plan type are not copied.")
            }
        }
    }

    // MARK: Regular prices

    /// Territories where the source has a current UPFRONT price but the clone cannot have it for lack of availability.
    static func lostTerritories(_ source: SubscriptionInfo, shared: Set<TerritoryCode>, _ snapshot: CatalogSnapshot,
                                _ today: CalendarDate) -> Set<TerritoryCode> {
        Set(snapshot.territories.keys).union(source.availableTerritories).subtracting(shared).filter {
            snapshot.currentRegular(subscriptionId: source.ascId, territory: $0, planType: .upfront, on: today) != nil
        }
    }

    static func regularSpec(_ source: SubscriptionInfo, _ clone: SubscriptionInfo, _ snapshot: CatalogSnapshot,
                            _ today: CalendarDate) -> PlanSpec? {
        var prices: [TerritoryAmount] = []
        for territory in source.availableTerritories.intersection(clone.availableTerritories).sorted() {
            guard let current = snapshot.currentRegular(subscriptionId: source.ascId, territory: territory, planType: .upfront, on: today),
                  snapshot.currentRegular(subscriptionId: clone.ascId, territory: territory, planType: .upfront, on: today) == nil,
                  snapshot.scheduledRegular(subscriptionId: clone.ascId, territory: territory, planType: .upfront, on: today) == nil else { continue }
            prices.append(TerritoryAmount(territory: territory, amount: current.customerPrice))
        }
        guard !prices.isEmpty else { return nil }
        return .regular(RegularPlanSpec(subscriptionIds: [clone.ascId], planType: .upfront, prices: prices, startDate: nil,
                                        preserveCurrentPrice: nil, skipIntroReplacement: [:], filter: PlanFilter()))
    }

    // MARK: Intro offers

    /// The shape rows share to go into one IntroPlanSpec.
    struct IntroShape: Hashable, Comparable {
        var future: Bool
        var mode: OfferMode
        var duration: OfferDuration?        // nil for free trials: their length may differ by territory
        var periods: Int
        var start: CalendarDate?            // nil for an offer that runs now: the clone's starts at once
        var end: CalendarDate?

        static func < (l: Self, r: Self) -> Bool {
            (l.future ? 1 : 0, l.mode.rawValue, l.duration?.rawValue ?? "", l.periods, l.start?.iso ?? "", l.end?.iso ?? "")
                < (r.future ? 1 : 0, r.mode.rawValue, r.duration?.rawValue ?? "", r.periods, r.start?.iso ?? "", r.end?.iso ?? "")
        }
    }

    static func shape(_ row: IntroOfferRow, future: Bool) -> IntroShape {
        IntroShape(future: future, mode: row.mode, duration: row.mode == .freeTrial ? nil : row.duration,
                   periods: row.mode == .freeTrial ? 1 : row.numberOfPeriods, start: future ? row.startDate : nil, end: row.endDate)
    }

    static func introSpecs(_ source: SubscriptionInfo, _ clone: SubscriptionInfo, shared: Set<TerritoryCode>, _ snapshot: CatalogSnapshot,
                           _ today: CalendarDate) -> (drafts: [(text: String, spec: PlanSpec)], notes: [String]) {
        var groups: [IntroShape: [IntroOfferRow]] = [:]
        for territory in shared.sorted() {
            if let row = snapshot.currentIntro(subscriptionId: source.ascId, territory: territory, planType: .upfront, on: today),
               snapshot.currentIntro(subscriptionId: clone.ascId, territory: territory, planType: .upfront, on: today) == nil {
                groups[shape(row, future: false), default: []].append(row)
            }
            if let row = snapshot.futureIntro(subscriptionId: source.ascId, territory: territory, planType: .upfront, on: today),
               snapshot.futureIntro(subscriptionId: clone.ascId, territory: territory, planType: .upfront, on: today) == nil {
                groups[shape(row, future: true), default: []].append(row)
            }
        }
        var drafts: [(text: String, spec: PlanSpec)] = []
        var notes: [String] = []
        for (shape, rows) in groups.sorted(by: { $0.key < $1.key }) {
            let territories = Set(rows.map(\.territory))
            if shape.mode == .freeTrial {
                var lengths: [TerritoryCode: OfferDuration] = [:]
                for row in rows { lengths[row.territory] = row.duration }
                let common = mostCommon(Array(lengths.values))
                let single = Set(lengths.values).count == 1
                drafts.append(("FREE_TRIAL " + (single ? common.rawValue : "of several lengths") + timing(shape),
                               .intro(IntroPlanSpec(subscriptionIds: [clone.ascId], mode: .freeTrial, duration: common, numberOfPeriods: 1,
                                                    pricing: single ? .freeTrial : .trialLengths(lengths), startDate: shape.start,
                                                    endDate: shape.end, nominalDiscount: nil, filter: PlanFilter(territories: territories),
                                                    canary: false))))
                continue
            }
            let duration = shape.duration ?? rows[0].duration
            let text = "\(shape.mode.rawValue) \(duration.rawValue)" + (shape.periods > 1 ? " × \(shape.periods)" : "") + timing(shape)
            let amounts = rows.compactMap { row in row.customerPrice.map { TerritoryAmount(territory: row.territory, amount: $0) } }
            // A paid offer is copied at the source's prices; without any, there is nothing for the table (and no tier to keep).
            guard !amounts.isEmpty else {
                notes.append("The introductory offer \(text) of \(source.productId) is not copied: the catalog has no price for it.")
                continue
            }
            drafts.append((text, .intro(IntroPlanSpec(subscriptionIds: [clone.ascId], mode: shape.mode, duration: duration,
                                                      numberOfPeriods: shape.periods, pricing: .table(amounts), startDate: shape.start,
                                                      endDate: shape.end, nominalDiscount: nil, filter: PlanFilter(territories: territories),
                                                      canary: false))))
        }
        return (drafts, notes)
    }

    /// The length most territories have; a tie goes to the shorter one.
    static func mostCommon(_ durations: [OfferDuration]) -> OfferDuration {
        let counts = Dictionary(durations.map { ($0, 1) }, uniquingKeysWith: +)
        let order = OfferDuration.allCases
        return counts.max { a, b in
            a.value != b.value ? a.value < b.value : (order.firstIndex(of: a.key) ?? 0) > (order.firstIndex(of: b.key) ?? 0)
        }?.key ?? .oneWeek
    }

    static func timing(_ shape: IntroShape) -> String {
        (shape.start.map { ", from \($0.iso)" } ?? ", at once") + (shape.end.map { " until \($0.iso)" } ?? "")
    }

    // MARK: Promotional offers

    /// One spec per UPFRONT offer of the source whose suffixed code the clone can take. An offer is left out, with a note,
    /// when its new code is too long or has characters the advisor refuses, was used before in the workspace (rule O1),
    /// is the code another clone of this pass gets, or when a paid offer has no price in a territory of the clone.
    static func promoSpecs(_ source: SubscriptionInfo, _ clone: SubscriptionInfo, suffix: String, _ snapshot: CatalogSnapshot,
                           claimedCodes: inout [String: String]) -> (drafts: [(code: String, spec: PlanSpec)], notes: [String]) {
        let existing = Set(snapshot.promoOffers(subscriptionId: clone.ascId).map(\.offerCode))
        var drafts: [(code: String, spec: PlanSpec)] = []
        var notes: [String] = []
        for offer in snapshot.promoOffers(subscriptionId: source.ascId) where offer.planType == .upfront {
            let code = offer.offerCode + suffix
            guard !existing.contains(code) else { continue }
            let left = "Promotional offer \(offer.name) of \(source.productId) not copied: "
            guard isUsableOfferCode(code) else {
                notes.append(left + "the code \(code) would be too long or invalid.")
                continue
            }
            guard !snapshot.offerCodesEverSeen.contains(code) else {
                notes.append(left + "the code \(code) was already used in this workspace and cannot be used again.")
                continue
            }
            if let other = claimedCodes[code] {
                notes.append(left + "the code \(code) goes to the clone of \(other); a code can be used only once.")
                continue
            }
            let pricing: IntroPricing
            if offer.mode == .freeTrial {
                pricing = .freeTrial
            } else {
                let amounts = offer.prices.filter { clone.availableTerritories.contains($0.territory) }.compactMap { price in
                    price.customerPrice.map { TerritoryAmount(territory: price.territory, amount: $0) }
                }
                guard !amounts.isEmpty else {
                    notes.append(left + "it has no price in a territory where the clone is available.")
                    continue
                }
                pricing = .table(amounts)
            }
            claimedCodes[code] = source.productId
            drafts.append((code, .promo(PromoPlanSpec(action: .create(subscriptionId: clone.ascId, offerCode: code, name: offer.name + suffix,
                                                                      mode: offer.mode, duration: offer.duration,
                                                                      numberOfPeriods: offer.numberOfPeriods, pricing: pricing)))))
        }
        return (drafts, notes)
    }

    // MARK: In-app purchase prices

    static func iapSpec(_ source: IAPInfo, _ clone: IAPInfo, _ snapshot: CatalogSnapshot, _ today: CalendarDate) -> PlanSpec? {
        guard snapshot.iapSchedules[clone.ascId] == nil, let schedule = snapshot.iapSchedules[source.ascId] else { return nil }
        var current: [TerritoryCode: IAPManualPrice] = [:]
        for price in schedule.manualPrices where (price.startDate.map { $0 <= today } ?? true) && (price.endDate.map { $0 > today } ?? true) {
            current[price.territory] = price
        }
        guard current[schedule.baseTerritory] != nil else { return nil }
        let prices = current.values.sorted { $0.territory < $1.territory }.map { TerritoryAmount(territory: $0.territory, amount: $0.customerPrice) }
        return .iap(IAPPlanSpec(iapId: clone.ascId, baseTerritory: schedule.baseTerritory, prices: prices, startDate: nil))
    }
}
