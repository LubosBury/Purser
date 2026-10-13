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

    static let live = IAPSchedule(iapId: "iap-1", scheduleId: "schedule-1", baseTerritory: "USA", manualPrices: [])
    let replace = PlannedItem(seq: 1, cell: .iapSchedule(iapId: "iap-1"),
                              payload: .replaceIAPSchedule(NewIAPSchedule(iapId: "iap-1", baseTerritory: "USA", manualPrices: [])),
                              before: .iapSchedule(IAPScheduleSpikeGateRuleTests.live), target: .iapSchedule(nil))
    /// A product that has no price schedule yet: nothing is replaced, so the open S10 question does not apply.
    let first = PlannedItem(seq: 1, cell: .iapSchedule(iapId: "iap-new"),
                            payload: .replaceIAPSchedule(NewIAPSchedule(iapId: "iap-new", baseTerritory: "USA", manualPrices: [])),
                            before: .iapSchedule(nil), target: .iapSchedule(nil))

    @Test func blocksScheduleReplaceUntilSpikeConfirmed() {
        let verdicts = IAPScheduleSpikeGateRule(confirmed: false).evaluate(context(items: [replace]))
        #expect(verdicts.count == 1)
        #expect(verdicts.first?.rule == "S10")
        #expect(verdicts.first?.severity == .block(.plan))
    }

    @Test func firstScheduleOfAProductWithoutOneIsNotGated() {
        #expect(IAPScheduleSpikeGateRule(confirmed: false).evaluate(context(items: [first])).isEmpty)
        #expect(IAPScheduleSpikeGateRule(confirmed: false).evaluate(context(items: [first, replace])).count == 1)
    }

    @Test func allowsAfterSpikeAndIgnoresOtherPlans() {
        #expect(IAPScheduleSpikeGateRule(confirmed: true).evaluate(context(items: [replace])).isEmpty)
        #expect(IAPScheduleSpikeGateRule(confirmed: false).evaluate(context(items: [])).isEmpty)
    }

    @Test func isPartOfDefaultPlanRules() {
        #expect(PolicyEngine.defaultPlanRules.contains { $0 is IAPScheduleSpikeGateRule })
    }
}
