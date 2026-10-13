import Foundation
import GRDB
import Testing
import Domain
import Store
import PurserTestSupport

@Suite struct PlanStoreTests {
    private func makePlan(id: String = "plan-1", state: PlanState = .draft) -> StoredPlan {
        StoredPlan(
            id: id, origin: .intro, specJSON: "{\"kind\":\"intro\"}", importJSON: nil, binding: PlanBinding(config: Sample.config()),
            baseSyncId: 3, state: state, pauseReason: nil, endReason: nil, planHash: "plan-hash", verdictHash: "verdict-hash",
            verdicts: [Verdict(rule: "I4", severity: .block(.cell), cell: .intro(subscriptionId: "6500000001", territory: "USA", planType: .upfront),
                               message: "intro is not cheaper than the regular price")],
            excluded: [.intro(subscriptionId: "6500000001", territory: "USA", planType: .upfront)],
            productStates: ["6500000001": .approved], reason: nil, confirmationLevel: .c1, appBuild: "0.1 (1)",
            estimateRequests: 4, estimateMinutes: 1, replanOf: nil,
            createdAt: Sample.fixedNow, updatedAt: Sample.fixedNow, heartbeatAt: nil)
    }

    private func makeItems() -> [PlannedItem] {
        let cell = CellKey.intro(subscriptionId: "6500000001", territory: "CZE", planType: .upfront)
        let current = Sample.intro("intro-1", territory: "CZE", mode: .payUpFront, duration: .threeMonths, price: "99", start: "2026-01-01")
        let delete = PlannedItem(seq: 1, cell: cell, payload: .deleteIntro(ascId: "intro-1"),
                                 before: .intro(current: current, future: nil), target: .intro(current: nil, future: nil),
                                 rules: ["I6"])
        let create = PlannedItem(
            seq: 2, cell: cell,
            payload: .createIntro(NewIntroOffer(subscriptionId: "6500000001", territory: "CZE", planType: .upfront, mode: .payUpFront,
                                                duration: .threeMonths, numberOfPeriods: 1, startDate: CalendarDate(iso: "2026-11-01"),
                                                endDate: nil, pricePointId: "pp-CZE-79")),
            before: .intro(current: nil, future: nil), target: .intro(current: nil, future: nil),
            dependsOn: [1], rules: ["I3", "I4"], flags: [.noOffer])
        return [delete, create]
    }

    @Test func insertAndLoadRoundTrip() throws {
        let store = PlanStore(database: try WorkspaceDatabase.inMemory())
        let plan = makePlan()
        let items = makeItems()
        try store.insert(plan, items: items)

        #expect(try store.plan(id: "plan-1") == plan)
        #expect(try store.plan(id: "missing") == nil)
        let loaded = try store.items(planId: "plan-1")
        #expect(loaded.map(\.item) == items)
        #expect(loaded.allSatisfy { $0.state == .pending && $0.attempts == 0 && $0.ascId == nil })
    }

    @Test func updatesPlanAndItemInsideATransaction() throws {
        let database = try WorkspaceDatabase.inMemory()
        let store = PlanStore(database: database)
        try store.insert(makePlan(), items: makeItems())

        var plan = try #require(try store.plan(id: "plan-1"))
        plan.state = .applying
        plan.pauseReason = .rate
        plan.heartbeatAt = Date(timeIntervalSince1970: 1_791_547_260)
        var item = try #require(try store.items(planId: "plan-1").last)
        item.state = .done
        item.attempts = 1
        item.ascId = "intro-2"
        item.verifiedAt = Date(timeIntervalSince1970: 1_791_547_270)
        try database.writer.write { db in
            try store.update(plan, in: db)
            try store.update(item, in: db)
        }

        #expect(try store.plan(id: "plan-1") == plan)
        #expect(try store.items(planId: "plan-1").last == item)
    }

    @Test func findsItemsByNaturalKeyAndAscId() throws {
        let database = try WorkspaceDatabase.inMemory()
        let store = PlanStore(database: database)
        try store.insert(makePlan(), items: makeItems())
        var item = try #require(try store.items(planId: "plan-1").last)
        item.ascId = "intro-2"
        try database.writer.write { db in try store.update(item, in: db) }

        #expect(try store.itemsMatching(naturalKey: "I-|intro-1").map(\.item.seq) == [1])
        #expect(try store.itemsMatching(naturalKey: "I+|6500000001|CZE|UPFRONT|PAY_UP_FRONT|THREE_MONTHS|pp-CZE-79|2026-11-01").map(\.item.seq) == [2])
        #expect(try store.itemsMatching(ascId: "intro-2").map(\.item.seq) == [2])
        #expect(try store.itemsMatching(ascId: "nothing").isEmpty)
    }

    @Test func filtersPlansByState() throws {
        let store = PlanStore(database: try WorkspaceDatabase.inMemory())
        try store.insert(makePlan(id: "a", state: .draft), items: [])
        try store.insert(makePlan(id: "b", state: .applying), items: [])
        try store.insert(makePlan(id: "c", state: .closed), items: [])
        #expect(try store.plans(states: nil).map(\.id) == ["a", "b", "c"])
        #expect(try store.plans(states: [.applying, .draft]).map(\.id) == ["a", "b"])
    }
}
