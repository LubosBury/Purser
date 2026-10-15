import Foundation
import Testing
import Domain
import Store
import MCPBridge
@testable import MCPTools
import PurserTestSupport

@Suite struct ReadyForReviewRenderingTests {
    @Test func readyForReviewNamesEachOwnerAndTheCallToAction() throws {
        let rendered = try #require(MCPRender.readyForReview([.iap("life"), .subscription("s"), .group("g")]) { "Name of \($0.ascId)" })
        #expect(rendered["message"] == "Ready for review: submit in App Store Connect")
        let owners = try #require(rendered["owners"]?.arrayValue)
        #expect(owners.map { $0["kind"] } == ["in_app_purchase", "subscription", "subscription_group"])
        #expect(owners.map { $0["asc_id"] } == ["life", "s", "g"])
        #expect(owners.first?["name"] == "Name of life")
        #expect(MCPRender.readyForReview([]) { $0.ascId } == nil)
    }

    @Test func incompleteVersionsNameEachOwnerAndTheMessage() throws {
        let rendered = try #require(MCPRender.incompleteVersions([.subscription("s")]) { _ in "Yearly" })
        #expect(rendered["message"] == "Not ready: some texts were not written; replan the rest first (replan_rest).")
        #expect(rendered["owners"]?.arrayValue?.first?["kind"] == "subscription")
        #expect(rendered["owners"]?.arrayValue?.first?["name"] == "Yearly")
        #expect(MCPRender.incompleteVersions([]) { $0.ascId } == nil)
    }

    @Test func aPlanCarriesReadyForReviewOnlyWhenGiven() throws {
        let config = SyntheticCatalog.config()
        let stored = StoredPlan(id: "p1", origin: .localization, specJSON: "{}", importJSON: nil, binding: PlanBinding(config: config),
                                baseSyncId: 1, state: .effective, pauseReason: nil, endReason: nil, planHash: "h", verdictHash: "v",
                                verdicts: [], excluded: [], productStates: [:], reason: nil, confirmationLevel: .c1, appBuild: "test",
                                estimateRequests: 3, estimateMinutes: 1, replanOf: nil, createdAt: Date(timeIntervalSince1970: 0),
                                updatedAt: Date(timeIntervalSince1970: 0), heartbeatAt: nil)
        let plain = MCPRender.plan(stored, items: [], rows: [], appName: config.name, productName: { $0 }, flaggedOnly: false, maxRows: 10)
        #expect(plain["ready_for_review"] == nil)
        let ready = MCPRender.readyForReview([.subscription("s")]) { _ in "Yearly" }
        let rendered = MCPRender.plan(stored, items: [], rows: [], appName: config.name, productName: { $0 }, flaggedOnly: false, maxRows: 10,
                                      readyForReview: ready)
        #expect(rendered["ready_for_review"]?["message"] == "Ready for review: submit in App Store Connect")
        #expect(rendered["ready_for_review"]?["owners"]?.arrayValue?.first?["name"] == "Yearly")
        #expect(rendered["incomplete_versions"] == nil)
        let incomplete = MCPRender.plan(stored, items: [], rows: [], appName: config.name, productName: { $0 }, flaggedOnly: false, maxRows: 10,
                                        incompleteVersions: MCPRender.incompleteVersions([.subscription("s")]) { _ in "Yearly" })
        #expect(incomplete["incomplete_versions"]?["message"] == "Not ready: some texts were not written; replan the rest first (replan_rest).")
        #expect(incomplete["ready_for_review"] == nil)
    }
}
