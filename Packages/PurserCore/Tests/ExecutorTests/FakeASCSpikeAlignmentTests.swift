import Foundation
import Testing
import Domain
import ASCClient
import PurserTestSupport

/// FakeASC (M2) must behave like App Store Connect did in spikes S7 and S10.
@Suite("FakeASC follows spikes S7 and S10")
struct FakeASCSpikeAlignmentTests {
    @Test func promoPatchFollowsTheS7Constant() async throws {
        let h = try await ExecutorHarness.make()
        _ = try await h.initialSync()
        let offer = try await h.writer.createPromotionalOffer(NewPromoOffer(
            subscriptionId: "sub-y", offerCode: "align_v1", name: "Align", mode: .payUpFront, duration: .oneMonth, numberOfPeriods: 1,
            planType: .upfront, prices: [NewPromoPrice(territory: "USA", pricePointId: "pp-sub-y-USA-3"),
                                         NewPromoPrice(territory: "CZE", pricePointId: "pp-sub-y-CZE-3")]))
        try await h.writer.replacePromotionalOfferPrices(ascId: offer.ascId,
                                                         prices: [NewPromoPrice(territory: "USA", pricePointId: "pp-sub-y-USA-2")])
        let snapshot = try await h.initialSync()
        let live = try #require(snapshot.promoOffers(subscriptionId: "sub-y").first { $0.offerCode == "align_v1" })
        #expect(live.prices.map(\.territory) == (AppleConstants.promoPatchReplacesPriceSet ? ["USA"] : ["CZE", "USA"]))
        #expect(live.prices.first { $0.territory == "USA" }?.pricePointId == "pp-sub-y-USA-2")
    }

    @Test func reusedOfferCodeAnswersWithTheRecordedError() async throws {
        let h = try await ExecutorHarness.make()
        let offer = NewPromoOffer(subscriptionId: "sub-y", offerCode: "reuse_v1", name: "Reuse", mode: .freeTrial, duration: .oneMonth,
                                  numberOfPeriods: 1, planType: .upfront, prices: [NewPromoPrice(territory: "USA", pricePointId: nil)])
        let created = try await h.writer.createPromotionalOffer(offer)
        try await h.writer.deletePromotionalOffer(ascId: created.ascId)
        do {
            _ = try await h.writer.createPromotionalOffer(offer)
            Issue.record("expected a 409 for a reused offer code")
        } catch let ASCError.http(status, code, _, detail) {
            #expect(status == 409)
            #expect(code == FakeASC.offerCodeReuseError.code)
            #expect(detail == FakeASC.offerCodeReuseError.detail)
        }
    }

    @Test(arguments: [false, true])
    func iapNullStartEchoFollowsTheS10Setting(echo: Bool) async throws {
        let h = try await ExecutorHarness.make()
        await h.fake.setIAPNullStartEchoesCreationDay(echo)
        try await h.writer.replaceIAPPriceSchedule(NewIAPSchedule(iapId: "iap-life", baseTerritory: "USA", manualPrices: [
            NewIAPManualPrice(territory: "USA", pricePointId: "pp-iap-life-USA-24", startDate: nil, endDate: nil),
        ]))
        let schedule = try #require(try await h.reader.iapPriceSchedule(iapId: "iap-life"))
        #expect(schedule.manualPrices.map(\.startDate) == [echo ? h.today : nil])
    }

    // MARK: Spike S10: the IAP price schedule POST

    @Test func scheduleIdStaysTheIAPIdAndUnchangedRowsKeepTheirIds() async throws {
        // What Apple did (S10-1, S10-3, S10-6r2, S10-9, S10-12).
        let before = try s10("schedule-before")
        let twoNow = try s10("post-two-now"), nowAndFuture = try s10("post-now-and-future")
        let oneNow = try s10("post-one-now"), again = try s10("post-identical-again")
        for post in [twoNow, nowAndFuture, oneNow, again] { #expect(post.scheduleId == before.scheduleId) }
        #expect(again.rowIds == oneNow.rowIds)
        #expect(Set(twoNow.rowIds).isDisjoint(with: nowAndFuture.rowIds))

        // What FakeASC does with the same sequence.
        let h = try await ExecutorHarness.make()
        let future = CalendarDate(iso: "2026-11-15")!
        try await h.writer.replaceIAPPriceSchedule(schedule([("USA", 14, nil, nil), ("GBR", 14, nil, nil)]))
        let first = try await liveSchedule(h)
        try await h.writer.replaceIAPPriceSchedule(schedule([("USA", 14, nil, future), ("USA", 24, future, nil)]))
        let second = try await liveSchedule(h)
        try await h.writer.replaceIAPPriceSchedule(schedule([("USA", 4, nil, nil)]))
        let third = try await liveSchedule(h)
        try await h.writer.replaceIAPPriceSchedule(schedule([("USA", 4, nil, nil)]))
        let fourth = try await liveSchedule(h)
        for live in [first, second, third, fourth] { #expect(live.id == "iap-life") }
        #expect(second.manualPrices.map(\.territory) == ["USA", "USA"])
        #expect(Set(first.manualPrices.map(\.id)).isDisjoint(with: second.manualPrices.map(\.id)))
        #expect(fourth.manualPrices.map(\.id) == third.manualPrices.map(\.id))
        #expect(try await h.reader.iapPriceSchedule(iapId: "iap-life")?.scheduleId == "iap-life")
    }

    @Test func scheduleWithoutABaseRowAnswersWithTheRecordedError() async throws {
        let recorded = try s10Error("post-no-base")
        #expect(FakeASC.iapScheduleNoBaseError.code == recorded.code)
        #expect(FakeASC.iapScheduleNoBaseError.detail == recorded.detail)

        let h = try await ExecutorHarness.make()
        let before = try await liveSchedule(h)
        await expectConflict(code: recorded.code, detail: recorded.detail) {
            try await h.writer.replaceIAPPriceSchedule(schedule([("GBR", 14, nil, nil)]))
        }
        #expect(try await liveSchedule(h) == before)
    }

    @Test func overlappingIntervalsAnswerWithTheRecordedError() async throws {
        let recorded = try s10Error("post-overlapping-intervals-409")
        let h = try await ExecutorHarness.make()
        let before = try await liveSchedule(h)
        let future = CalendarDate(iso: "2026-11-15")!
        // S10-6: the template's first row had no endDate.
        await expectConflict(code: recorded.code, detail: recorded.detail) {
            try await h.writer.replaceIAPPriceSchedule(schedule([("USA", 14, nil, nil), ("USA", 24, future, nil)]))
        }
        #expect(try await liveSchedule(h) == before)
        // Rows of different territories never overlap each other; rows that only touch are accepted (S10-6r2).
        try await h.writer.replaceIAPPriceSchedule(schedule([("USA", 14, nil, future), ("USA", 24, future, nil), ("GBR", 14, nil, nil)]))
        #expect(try await liveSchedule(h).manualPrices.count == 3)
    }
}

// MARK: S10 helpers

private func schedule(_ rows: [(territory: TerritoryCode, point: Int, start: CalendarDate?, end: CalendarDate?)]) -> NewIAPSchedule {
    NewIAPSchedule(iapId: "iap-life", baseTerritory: "USA", manualPrices: rows.map {
        NewIAPManualPrice(territory: $0.territory, pricePointId: "pp-iap-life-\($0.territory.rawValue)-\($0.point)",
                          startDate: $0.start, endDate: $0.end)
    })
}

private func liveSchedule(_ h: ExecutorHarness) async throws -> FakeIAPSchedule {
    try #require(await h.fake.model.iapSchedules.first { $0.iapId == "iap-life" })
}

private func expectConflict(code: String, detail: String, _ write: () async throws -> Void) async {
    do {
        try await write()
        Issue.record("expected a 409 \(code)")
    } catch let ASCError.http(status, actualCode, _, actualDetail) {
        #expect(status == 409)
        #expect(actualCode == code)
        #expect(actualDetail == detail)
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

/// The schedule id and the manual price row ids of an S10 fixture with a schedule document.
private func s10(_ name: String) throws -> (scheduleId: String, rowIds: [String]) {
    let root = try #require(try JSONSerialization.jsonObject(with: Fixtures.data("spikes/S10/\(name).json")) as? [String: Any])
    let data = try #require(root["data"] as? [String: Any])
    let rows = ((data["relationships"] as? [String: Any])?["manualPrices"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
    return (try #require(data["id"] as? String), rows.compactMap { $0["id"] as? String })
}

private func s10Error(_ name: String) throws -> (code: String, detail: String) {
    let root = try #require(try JSONSerialization.jsonObject(with: Fixtures.data("spikes/S10/\(name).json")) as? [String: Any])
    let first = try #require((root["errors"] as? [[String: Any]])?.first)
    return (try #require(first["code"] as? String), try #require(first["detail"] as? String))
}
