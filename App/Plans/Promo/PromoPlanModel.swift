import Foundation
import Observation
import Domain
import Catalog
import Importer
import Planner

@MainActor @Observable
final class PromoPlanModel {
    enum Action: String, CaseIterable, Identifiable {
        case create = "New offer", reprice = "Reprice", delete = "Delete"
        var id: String { rawValue }
    }

    enum PricingChoice: String, CaseIterable, Identifiable {
        case percent = "% of the regular price", table = "Table", freeTrial = "Free trial"
        var id: String { rawValue }
    }

    let snapshot: CatalogSnapshot
    let config: WorkspaceConfig
    let today: CalendarDate
    let registryEntries: [OfferCodeRegistryEntry]
    @ObservationIgnored private let planning: PlanningModel
    @ObservationIgnored private let planner: Planner
    @ObservationIgnored private let names: TerritoryNameMap

    var action: Action = .create
    var subscriptionId: String?
    var offerCode = ""
    var offerName = ""
    var mode: OfferMode = .payUpFront
    var duration: OfferDuration = .oneMonth
    var numberOfPeriods = 1
    var pricingChoice: PricingChoice = .percent
    var percentText = "50"
    var tableText = ""
    var selectedOfferAscId: String?
    var confirmedUnusedByApp = false
    var reason = ""

    private(set) var draft: PlanDraft?
    private(set) var lastSpec: PlanSpec?
    private(set) var buildError: String?
    private(set) var tableErrors: [PastedAmountLineError] = []

    init(planning: PlanningModel, snapshot: CatalogSnapshot, registryEntries: [OfferCodeRegistryEntry]) {
        self.planning = planning
        self.snapshot = snapshot
        self.config = planning.config
        self.today = planning.today
        self.registryEntries = registryEntries
        self.planner = planning.sharedPlanner
        self.names = planning.names
    }

    /// nil while the workspace has no snapshot yet.
    static func make(planning: PlanningModel) throws -> PromoPlanModel? {
        guard let snapshot = planning.snapshot else { return nil }
        return PromoPlanModel(planning: planning, snapshot: snapshot,
                              registryEntries: try OfferCodeRegistryReader(database: planning.database).entries())
    }

    var subscriptions: [SubscriptionInfo] { snapshot.subscriptions.values.sorted { $0.productId < $1.productId } }
    var offers: [PromoOffer] { subscriptionId.map { snapshot.promoOffers(subscriptionId: $0) } ?? [] }
    var selectedOffer: PromoOffer? { offers.first { $0.ascId == selectedOfferAscId } }
    var advisor: OfferCodeAdvisor { OfferCodeAdvisor(registry: snapshot.offerCodesEverSeen) }
    var codeCheck: OfferCodeCheck { advisor.check(offerCode) }
    var isFreeTrialMode: Bool { action == .create ? mode == .freeTrial : selectedOffer?.mode == .freeTrial }

    var inputsFingerprint: String {
        [action.rawValue, subscriptionId ?? "", offerCode, offerName, mode.rawValue, duration.rawValue, String(numberOfPeriods),
         pricingChoice.rawValue, percentText, tableText, selectedOfferAscId ?? "", String(confirmedUnusedByApp)]
            .joined(separator: "|")
    }

    func suggestCode() {
        let seed = offerCode.isEmpty ? (offerName.isEmpty ? "promo" : offerName) : offerCode
        if let suggestion = advisor.suggestion(for: seed) { offerCode = suggestion }
    }

    var coverage: PromoCoverage? {
        guard let draft else { return nil }
        let sid = action == .create ? subscriptionId : selectedOffer?.subscriptionId
        guard let sid, let available = snapshot.subscriptions[sid]?.availableTerritories else { return nil }
        for item in draft.items {
            switch item.payload {
            case let .createPromo(offer):
                return PromoCoverage(prices: offer.prices, available: available, mode: offer.mode)
            case let .replacePromoPrices(_, prices):
                return PromoCoverage(prices: prices, available: available, mode: selectedOffer?.mode ?? .payUpFront)
            default:
                continue
            }
        }
        return nil
    }

    var planBlockingVerdicts: [Verdict] {
        (draft?.verdicts ?? []).filter { $0.severity == .block(.plan) }
    }

    var canSave: Bool {
        guard let draft, lastSpec != nil else { return false }
        return !draft.items.isEmpty && planBlockingVerdicts.isEmpty
    }

    private func pricing() -> IntroPricing? {
        if isFreeTrialMode { return action == .create ? .freeTrial : nil }
        switch pricingChoice {
        case .freeTrial:
            return nil
        case .percent:
            let text = percentText.replacingOccurrences(of: ",", with: ".")
            guard let percent = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), percent > 0, percent < 100 else { return nil }
            return .percentOfRegular(percent / 100)
        case .table:
            let parsed = PastedAmountTable.parse(tableText, names: names, known: Set(snapshot.territories.keys))
            tableErrors = parsed.errors
            return parsed.errors.isEmpty && !parsed.amounts.isEmpty ? .table(parsed.amounts) : nil
        }
    }

    private func spec() -> PlanSpec? {
        switch action {
        case .create:
            let name = offerName.trimmingCharacters(in: .whitespaces)
            guard let sid = subscriptionId, codeCheck.isAcceptable, !name.isEmpty, let pricing = pricing() else { return nil }
            return .promo(PromoPlanSpec(action: .create(subscriptionId: sid, offerCode: offerCode, name: name, mode: mode,
                                                        duration: duration, numberOfPeriods: numberOfPeriods, pricing: pricing)))
        case .reprice:
            guard let offer = selectedOffer, let pricing = pricing() else { return nil }
            return .promo(PromoPlanSpec(action: .reprice(offerAscId: offer.ascId, pricing: pricing)))
        case .delete:
            guard let offer = selectedOffer, confirmedUnusedByApp else { return nil }
            return .promo(PromoPlanSpec(action: .delete(offerAscId: offer.ascId, confirmedUnusedByApp: true)))
        }
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

    /// Stores the Draft through PlanningModel.build (same snapshot, audit planCreated) and opens the Plan screen.
    /// Returns nil on success, else the message to show.
    func save() async -> String? {
        guard canSave, let lastSpec else { return "The plan is not built." }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if await planning.build(lastSpec, reason: trimmed.isEmpty ? nil : trimmed) { return nil }
        let message = planning.errorMessage ?? "The plan cannot be saved."
        planning.errorMessage = nil
        return message
    }
}
