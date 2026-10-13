import Testing
import Domain

@Suite struct PlanTypeCanonicalizerTests {
    @Test func explicitValuesWin() {
        #expect(PlanTypeCanonicalizer.canonical(raw: "UPFRONT", monthlyPlanAvailable: true) == .upfront)
        #expect(PlanTypeCanonicalizer.canonical(raw: "MONTHLY", monthlyPlanAvailable: true) == .monthly)
        #expect(PlanTypeCanonicalizer.canonical(raw: "MONTHLY", monthlyPlanAvailable: false) == .monthly)
    }

    @Test func missingValueMeansUpfrontWithoutMonthlyAvailability() {
        #expect(PlanTypeCanonicalizer.canonical(raw: nil, monthlyPlanAvailable: false) == .upfront)
    }

    @Test func missingValueIsAmbiguousWithMonthlyAvailability() {
        #expect(PlanTypeCanonicalizer.canonical(raw: nil, monthlyPlanAvailable: true) == nil)
    }

    @Test func unknownValueFallsBackLikeMissing() {
        #expect(PlanTypeCanonicalizer.canonical(raw: "WEEKLY", monthlyPlanAvailable: false) == .upfront)
        #expect(PlanTypeCanonicalizer.canonical(raw: "WEEKLY", monthlyPlanAvailable: true) == nil)
    }
}
