import Foundation
import Testing
import Domain
import Store
@testable import Executor

private func day(_ s: String) -> CalendarDate { CalendarDate(iso: s)! }
private let now = ISO8601DateFormatter().date(from: "2026-10-09T08:00:00Z")!
/// Derived from AppleConstants so spikes S5/S6 can change the constants without touching these tests.
private let earliest = CalendarDate.today(now: now).adding(days: AppleConstants.minLeadDays).iso
private let tooEarly = CalendarDate.today(now: now).adding(days: AppleConstants.minLeadDays - 1).iso
private let safeDeleteStart = CalendarDate.today(now: now)
    .adding(days: Int((Double(AppleConstants.replaceCutoffHours) / 24).rounded(.up)) + 1).iso

private func request(level: ConfirmationLevel, excluded: [CellKey] = [], classes: [String: Int] = [:]) -> ConfirmationRequest {
    ConfirmationRequest(planId: "p", level: level, verdicts: [], excluded: excluded, riskClasses: classes,
                        verdictHashChanged: false, appName: "FruitJar")
}

private func response(accepted: Bool = true, ack: Bool = true, name: String? = nil, reason: String? = nil,
                      checked: Set<String> = []) -> ConfirmationResponse {
    ConfirmationResponse(accepted: accepted, acknowledgedExclusions: ack, typedAppName: name, reason: reason, checkedRiskClasses: checked)
}

private let cze = CellKey.regular(subscriptionId: "sub-y", territory: "CZE", planType: .upfront)

private func regularItem(start: String?, before: CellState = .regular(current: nil, scheduled: nil)) -> PlannedItem {
    PlannedItem(seq: 1, cell: cze, payload: .createRegularPrice(NewRegularPrice(subscriptionId: "sub-y", territory: "CZE", planType: .upfront,
                pricePointId: "pp", startDate: start.map(day), preserveCurrentPrice: true)), before: before, target: before)
}

private func stored(_ payload: WritePayload, _ state: ItemState, verified: Bool = true) -> StoredItem {
    StoredItem(planId: "p", item: PlannedItem(seq: 1, cell: cze, payload: payload, before: .regular(current: nil, scheduled: nil),
                                              target: .regular(current: nil, scheduled: nil)),
               state: state, attempts: 1, ascId: nil, errorJSON: nil, verifiedAt: verified ? now : nil, effectiveAt: nil, supersededBy: nil)
}

@Suite("Executor pure parts")
struct ExecutorPureTests {
    @Test func c0NeedsAcceptanceAndAcknowledgedExclusions() {
        #expect(ConfirmationValidator.problems(request: request(level: .c0), response: response()).isEmpty)
        #expect(!ConfirmationValidator.problems(request: request(level: .c0), response: response(accepted: false)).isEmpty)
        #expect(!ConfirmationValidator.problems(request: request(level: .c0, excluded: [cze]), response: response(ack: false)).isEmpty)
        #expect(ConfirmationValidator.problems(request: request(level: .c0, excluded: [cze]), response: response(ack: true)).isEmpty)
    }

    @Test func c1NeedsExactAppName() {
        #expect(!ConfirmationValidator.problems(request: request(level: .c1), response: response(name: "Fruitjar")).isEmpty)
        #expect(!ConfirmationValidator.problems(request: request(level: .c1), response: response(name: nil)).isEmpty)
        #expect(ConfirmationValidator.problems(request: request(level: .c1), response: response(name: " FruitJar ")).isEmpty)
    }

    @Test func c2NeedsLongReasonAndEveryRiskClass() {
        let classes = ["R7 decrease": 3, "R8 increase without preserve": 1]
        let long = "Synthetic quarterly repricing approved"
        #expect(!ConfirmationValidator.problems(request: request(level: .c2, classes: classes),
                                                response: response(name: "FruitJar", reason: "too short", checked: Set(classes.keys))).isEmpty)
        #expect(!ConfirmationValidator.problems(request: request(level: .c2, classes: classes),
                                                response: response(name: "FruitJar", reason: long, checked: ["R7 decrease"])).isEmpty)
        #expect(ConfirmationValidator.problems(request: request(level: .c2, classes: classes),
                                               response: response(name: "FruitJar", reason: long, checked: Set(classes.keys))).isEmpty)
    }

    @Test func r4LeadTimeOnApprovedSubscriptions() {
        #expect(DeadlineCheck.violation(regularItem(start: tooEarly), productState: .approved, now: now) != nil)
        #expect(DeadlineCheck.violation(regularItem(start: earliest), productState: .approved, now: now) == nil)
        #expect(DeadlineCheck.violation(regularItem(start: tooEarly), productState: .readyToSubmit, now: now) == nil)
        #expect(DeadlineCheck.violation(regularItem(start: "2026-10-08"), productState: .readyToSubmit, now: now) != nil)
        let existing = CellState.regular(current: RegularPriceRow(ascId: "r1", subscriptionId: "sub-y", territory: "CZE", planType: .upfront,
                                                                  rawPlanType: "UPFRONT", startDate: day("2026-01-01"), preserved: false,
                                                                  pricePointId: "pp", customerPrice: 1), scheduled: nil)
        #expect(DeadlineCheck.violation(regularItem(start: nil, before: existing), productState: .missingMetadata, now: now) != nil)
        #expect(DeadlineCheck.violation(regularItem(start: nil), productState: .missingMetadata, now: now) == nil)
    }

    @Test func r4AndI7ForIntrosOnApprovedSubscriptions() {
        let cell = CellKey.intro(subscriptionId: "sub-y", territory: "DEU", planType: .upfront)
        func intro(_ start: String?) -> PlannedItem {
            PlannedItem(seq: 1, cell: cell, payload: .createIntro(NewIntroOffer(subscriptionId: "sub-y", territory: "DEU", planType: .upfront,
                        mode: .freeTrial, duration: .oneWeek, numberOfPeriods: 1, startDate: start.map(day), endDate: nil, pricePointId: nil)),
                        before: .intro(current: nil, future: nil), target: .intro(current: nil, future: nil))
        }
        func end(_ date: String) -> PlannedItem {
            PlannedItem(seq: 1, cell: cell, payload: .endIntro(ascId: "i1", endDate: day(date)),
                        before: .intro(current: nil, future: nil), target: .intro(current: nil, future: nil))
        }
        #expect(DeadlineCheck.violation(intro(nil), productState: .approved, now: now) != nil)
        #expect(DeadlineCheck.violation(intro(tooEarly), productState: .approved, now: now) != nil)
        #expect(DeadlineCheck.violation(intro(earliest), productState: .approved, now: now) == nil)
        #expect(DeadlineCheck.violation(intro(nil), productState: .missingMetadata, now: now) == nil)
        #expect(DeadlineCheck.violation(end(tooEarly), productState: .approved, now: now) != nil)
        #expect(DeadlineCheck.violation(end(earliest), productState: .approved, now: now) == nil)
    }

    @Test func r6ReplaceCutoffBeforeScheduledStart() {
        func delete(start: String) -> PlannedItem {
            let row = RegularPriceRow(ascId: "s1", subscriptionId: "sub-y", territory: "CZE", planType: .upfront, rawPlanType: "UPFRONT",
                                      startDate: day(start), preserved: false, pricePointId: "pp", customerPrice: 1)
            return PlannedItem(seq: 1, cell: cze, payload: .deleteRegularPrice(ascId: "s1"),
                               before: .regular(current: nil, scheduled: row), target: .regular(current: nil, scheduled: nil))
        }
        #expect(DeadlineCheck.violation(delete(start: "2026-10-10"), productState: .missingMetadata, now: now) != nil)
        #expect(DeadlineCheck.violation(delete(start: safeDeleteStart), productState: .approved, now: now) == nil)
    }

    @Test func immediateEffectiveness() {
        let today = day("2026-10-09")
        #expect(ItemEffectiveness.immediately(regularItem(start: "2026-11-01"), today: today) == false)
        #expect(ItemEffectiveness.immediately(regularItem(start: nil), today: today))
        #expect(ItemEffectiveness.immediately(stored(.deletePromo(ascId: "o"), .done).item, today: today))
        #expect(ItemEffectiveness.immediately(stored(.endIntro(ascId: "i", endDate: day("2026-11-01")), .done).item, today: today) == false)
    }

    @Test func outcomeAfterApply() {
        let post = WritePayload.createRegularPrice(NewRegularPrice(subscriptionId: "sub-y", territory: "CZE", planType: .upfront,
                                                                   pricePointId: "pp", startDate: day("2026-11-01"), preserveCurrentPrice: true))
        let del = WritePayload.deleteRegularPrice(ascId: "x")
        #expect(OutcomeCalculator.afterApply([stored(del, .effective)]) == .effective)
        #expect(OutcomeCalculator.afterApply([stored(del, .effective), stored(post, .done)]) == .scheduled)
        #expect(OutcomeCalculator.afterApply([stored(del, .effective), stored(post, .failed)]) == .partiallyApplied)
        #expect(OutcomeCalculator.afterApply([stored(del, .done), stored(post, .mismatch)]) == .partiallyApplied)
        #expect(OutcomeCalculator.afterApply([stored(del, .stale), stored(post, .skipped)]) == .stale)
        #expect(OutcomeCalculator.afterApply([stored(del, .superseded), stored(post, .effective)]) == .effective)
    }
}
