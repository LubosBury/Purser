import Foundation
import Observation
import Domain
import Catalog
import Importer
import Planner

@MainActor @Observable
final class RegularPlanModel {
    enum PreserveChoice: String, CaseIterable, Identifiable {
        case unset = "Not selected", keep = "Yes, existing subscribers keep their price", drop = "No, existing subscribers get the new price too"
        var id: String { rawValue }
    }

    struct PromoChoice: Identifiable, Hashable {
        let offer: PromoOffer
        var enabled: Bool
        var percentText: String
        var id: String { offer.ascId }
    }

    let snapshot: CatalogSnapshot
    let config: WorkspaceConfig
    let today: CalendarDate
    @ObservationIgnored private let planning: PlanningModel
    @ObservationIgnored private let planner: Planner
    @ObservationIgnored private let names: TerritoryNameMap

    var selectedSubscriptionIds: Set<String> = []
    var tableText = ""
    /// "Price in one territory, converted to all": fills `tableText` from Apple's equalizations.
    var baseTerritoryText = "USA"
    var baseAmountText = ""
    private(set) var isEqualizing = false
    private(set) var equalizeMessage: String?
    var territoryFilterText = ""
    var startDate: Date
    /// First price of a product that has none: sent without a start date, so it applies at once (the Planner
    /// blocks it with R4 in a cell that already has a price).
    var startImmediately = false
    var preserve: PreserveChoice = .unset
    var skipReasons: [String: String] = [:]          // CellKey.storageKey -> reason (I8)
    var promoChoices: [PromoChoice] = []
    var reason = ""
    private(set) var tableErrors: [PastedAmountLineError] = []
    private(set) var draft: PlanDraft?
    private(set) var lastSpec: PlanSpec?
    private(set) var buildError: String?

    init(planning: PlanningModel, snapshot: CatalogSnapshot) {
        self.planning = planning
        self.snapshot = snapshot
        self.config = planning.config
        self.today = planning.today
        self.planner = planning.sharedPlanner
        self.names = planning.names
        self.startDate = planning.today.adding(days: 3).startOfDayUTC
    }

    /// nil while the workspace has no snapshot yet.
    static func make(planning: PlanningModel) -> RegularPlanModel? {
        guard let snapshot = planning.snapshot else { return nil }
        return RegularPlanModel(planning: planning, snapshot: snapshot)
    }

    var subscriptions: [SubscriptionInfo] { snapshot.subscriptions.values.sorted { $0.productId < $1.productId } }

    /// Fills the table with the price of every territory that Apple treats as equal to the base price (one GET).
    /// The ladder is taken from the first selected subscription.
    func fillFromBasePrice() async {
        equalizeMessage = nil
        guard let subscriptionId = selectedSubscriptionIds.sorted().first else {
            equalizeMessage = "Tick a subscription first."
            return
        }
        let territory = TerritoryCode(baseTerritoryText.trimmingCharacters(in: .whitespaces).uppercased())
        guard let amount = Decimal(string: baseAmountText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")), amount > 0 else {
            equalizeMessage = "Enter the price as a number, e.g. 29.99."
            return
        }
        guard let base = EqualizedPrices.basePoint(in: snapshot.pricePoints, productAscId: subscriptionId, territory: territory,
                                                   planType: .upfront, amount: amount) else {
            equalizeMessage = "The price \(amount) is not on this subscription's price ladder in \(territory.rawValue) (or the price points are missing; run a sync)."
            return
        }
        guard let equalizer = planning.equalizer else {
            equalizeMessage = "Reading from App Store Connect is not available (the key is missing or you are offline)."
            return
        }
        isEqualizing = true
        defer { isEqualizing = false }
        do {
            let equalized = try await equalizer(subscriptionId, base.id, .upfront)
            tableText = EqualizedPrices.tableText(base: base, equalized: equalized)
            // A product without any price gets its first price at once.
            if !snapshot.regularRows.contains(where: { $0.subscriptionId == subscriptionId }) { startImmediately = true }
            equalizeMessage = "Filled \(equalized.count + 1) territories from \(territory.rawValue) \(amount)."
        } catch {
            equalizeMessage = "The recalculation failed: \(error)"
        }
    }

    func setSelected(_ subscriptionId: String, _ selected: Bool) {
        if selected { selectedSubscriptionIds.insert(subscriptionId) } else { selectedSubscriptionIds.remove(subscriptionId) }
        let offers = selectedSubscriptionIds.flatMap { snapshot.promoOffers(subscriptionId: $0) }
            .filter { $0.mode == .payAsYouGo }
            .sorted { $0.offerCode < $1.offerCode }
        promoChoices = offers.map { offer in
            promoChoices.first { $0.id == offer.ascId } ?? PromoChoice(offer: offer, enabled: false, percentText: "50")
        }
    }

    var i8Cells: [CellKey] {
        let cells = (draft?.verdicts ?? []).filter { $0.rule == "I8" }.compactMap(\.cell)
        return Array(Set(cells)).sorted { $0.storageKey < $1.storageKey }
    }

    var planBlockingVerdicts: [Verdict] { (draft?.verdicts ?? []).filter { $0.severity == .block(.plan) } }
    var warnings: [Verdict] { (draft?.verdicts ?? []).filter { $0.severity == .warn } }
    var canSave: Bool { (draft.map { !$0.items.isEmpty } ?? false) && lastSpec != nil && planBlockingVerdicts.isEmpty }

    var inputsFingerprint: String {
        [selectedSubscriptionIds.sorted().joined(separator: ","), tableText, territoryFilterText,
         String(startDate.timeIntervalSince1970), String(startImmediately), preserve.rawValue,
         skipReasons.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";"),
         promoChoices.map { "\($0.id):\($0.enabled):\($0.percentText)" }.joined(separator: ";")]
            .joined(separator: "|")
    }

    private func spec() -> PlanSpec? {
        guard !selectedSubscriptionIds.isEmpty else { return nil }
        let parsed = PastedAmountTable.parse(tableText, names: names, known: Set(snapshot.territories.keys))
        tableErrors = parsed.errors
        guard parsed.errors.isEmpty, !parsed.amounts.isEmpty else { return nil }
        let codes = territoryFilterText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { TerritoryCode($0) }
        var skip: [CellKey: String] = [:]
        for (key, reason) in skipReasons {
            let trimmed = reason.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, let cell = CellKey(storageKey: key) { skip[cell] = trimmed }
        }
        var repricing: [String: IntroPricing] = [:]
        for choice in promoChoices where choice.enabled {
            let text = choice.percentText.replacingOccurrences(of: ",", with: ".")
            if let percent = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), percent > 0, percent < 100 {
                repricing[choice.id] = .percentOfRegular(percent / 100)
            }
        }
        let preserveValue: Bool? = switch preserve {
        case .unset: nil
        case .keep: true
        case .drop: false
        }
        return .regular(RegularPlanSpec(subscriptionIds: selectedSubscriptionIds.sorted(), planType: .upfront, prices: parsed.amounts,
                                        startDate: startImmediately ? nil : CalendarDate.today(now: startDate), preserveCurrentPrice: preserveValue,
                                        skipIntroReplacement: skip,
                                        filter: PlanFilter(productAscIds: nil, territories: codes.isEmpty ? nil : Set(codes)),
                                        promoRepricing: repricing))
    }

    /// Called debounced from the view; never from `body`.
    func rebuild() {
        tableErrors = []
        guard let spec = spec() else { draft = nil; lastSpec = nil; buildError = nil; return }
        do {
            draft = try planner.plan(spec, context: PlanningContext(snapshot: snapshot, config: config, today: today))
            lastSpec = spec
            buildError = nil
        } catch {
            draft = nil
            lastSpec = nil
            buildError = String(describing: error)
        }
    }

    /// Stores the Draft through PlanningModel.build and opens the Plan screen. nil on success, else the message to show.
    func save() async -> String? {
        guard canSave, let lastSpec else { return "The plan is not built." }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if await planning.build(lastSpec, reason: trimmed.isEmpty ? nil : trimmed) { return nil }
        let message = planning.errorMessage ?? "The plan cannot be saved."
        planning.errorMessage = nil
        return message
    }
}
