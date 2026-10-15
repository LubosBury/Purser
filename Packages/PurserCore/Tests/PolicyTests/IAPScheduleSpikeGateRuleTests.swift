import Foundation
import Testing
import Domain
import Catalog
import Policy

@Suite struct IAPScheduleSpikeGateRuleTests {
    func context(items: [PlannedItem]) -> PolicyContext {
        let snapshot = CatalogSnapshot(syncId: 1, takenAt: Date(timeIntervalSince1970: 0), subscriptions: [:], iaps: [:], territories: [:],
                                       regularRows: [], introRows: [], promoOffers: [], iapSchedules: [:],
                                       pricePoints: PricePointIndex([]), offerCodesEverSeen: [])
        let config = WorkspaceConfig(id: UUID(), name: "Test", colorHex: "#336699", isProduction: false, appId: "1000000001",
                                     bundleId: "com.example.test", keyKind: .team, keyId: "KEY1", issuerId: "issuer",
                                     importMapping: nil, googleClientId: nil, slackWebhookEnabled: false, nightlySyncHourUTC: 3)
        return PolicyContext(snapshot: snapshot, config: config, today: CalendarDate(year: 2030, month: 3, day: 1),
                             spec: PlanSpecSummary(origin: .iap, canary: false, nominalDiscounts: [:], skippedIntroReplacements: [:]),
                             items: items, liveBinding: nil, liveBundleId: nil, otherApplyingPlanIds: [])
    }

    static let live = IAPSchedule(iapId: "iap-1", scheduleId: "schedule-1", baseTerritory: "USA", manualPrices: [
        IAPManualPrice(ascId: "price-1", territory: "USA", pricePointId: "pp-usa", startDate: nil, endDate: nil, customerPrice: 29.99)])
    static let baseOnly = IAPSchedule(iapId: "iap-1", scheduleId: "schedule-1", baseTerritory: "USA", manualPrices: [])
    static func item(_ iapId: String, before: IAPSchedule?, base: TerritoryCode = "USA") -> PlannedItem {
        PlannedItem(seq: 1, cell: .iapSchedule(iapId: iapId),
                    payload: .replaceIAPSchedule(NewIAPSchedule(iapId: iapId, baseTerritory: base, manualPrices: [])),
                    before: .iapSchedule(before), target: .iapSchedule(nil))
    }
    let replace = item("iap-1", before: live)
    /// A product that has no price schedule yet: nothing is replaced, so exception S10a applies.
    let first = item("iap-new", before: nil)

    @Test func blocksScheduleReplaceUntilSpikeConfirmed() {
        let verdicts = IAPScheduleSpikeGateRule(confirmed: false).evaluate(context(items: [replace]))
        #expect(verdicts.count == 1)
        #expect(verdicts.first?.rule == "S10")
        #expect(verdicts.first?.severity == .block(.plan))
    }

    @Test func firstScheduleOfAProductWithoutOneWarnsWithS10a() {
        let verdicts = IAPScheduleSpikeGateRule(confirmed: false).evaluate(context(items: [first]))
        #expect(verdicts.map(\.rule) == ["S10a"])
        #expect(verdicts.first?.severity == .warn)
        #expect(verdicts.first?.cell == .iapSchedule(iapId: "iap-new"))
    }

    @Test func scheduleWithoutManualPricesKeepingItsBaseWarnsWithS10a() {
        let verdicts = IAPScheduleSpikeGateRule(confirmed: false).evaluate(context(items: [Self.item("iap-1", before: Self.baseOnly)]))
        #expect(verdicts.map(\.rule) == ["S10a"])
        #expect(!verdicts.contains { $0.severity == .block(.plan) })
    }

    @Test func scheduleWithoutManualPricesChangingItsBaseIsBlocked() {
        let verdicts = IAPScheduleSpikeGateRule(confirmed: false)
            .evaluate(context(items: [Self.item("iap-1", before: Self.baseOnly, base: "CZE")]))
        #expect(verdicts.map(\.rule) == ["S10"])
    }

    @Test func manualPriceInTheSnapshotBlocksAlthoughBeforeHadNone() {
        // The preflight re-syncs before the rule runs: the snapshot shows a manual price the planned `before` did not.
        var fresh = context(items: [Self.item("iap-1", before: Self.baseOnly)])
        fresh.snapshot = CatalogSnapshot(syncId: 2, takenAt: Date(timeIntervalSince1970: 0), subscriptions: [:], iaps: [:], territories: [:],
                                         regularRows: [], introRows: [], promoOffers: [], iapSchedules: ["iap-1": Self.live],
                                         pricePoints: PricePointIndex([]), offerCodesEverSeen: [])
        #expect(IAPScheduleSpikeGateRule(confirmed: false).evaluate(fresh).map(\.rule) == ["S10"])
    }

    @Test func mixedPlanKeepsTheBlock() {
        let verdicts = IAPScheduleSpikeGateRule(confirmed: false).evaluate(context(items: [first, replace]))
        #expect(verdicts.contains { $0.rule == "S10" && $0.severity == .block(.plan) })
        #expect(verdicts.contains { $0.rule == "S10a" && $0.cell == .iapSchedule(iapId: "iap-new") })
    }

    @Test func allowsAfterSpikeAndIgnoresOtherPlans() {
        #expect(IAPScheduleSpikeGateRule(confirmed: true).evaluate(context(items: [replace])).isEmpty)
        #expect(IAPScheduleSpikeGateRule(confirmed: true).evaluate(context(items: [first])).isEmpty)
        #expect(IAPScheduleSpikeGateRule(confirmed: false).evaluate(context(items: [])).isEmpty)
    }

    @Test func isPartOfDefaultPlanRules() {
        #expect(PolicyEngine.defaultPlanRules.contains { $0 is IAPScheduleSpikeGateRule })
    }
}
