import Testing
import Planner

@Suite struct OfferCodeAdvisorTests {
    let advisor = OfferCodeAdvisor(registry: ["spring_v1", "spring_v3", "Winter", "summer"])

    @Test func freeCodeHasNoProblems() {
        let check = advisor.check("autumn_v1")
        #expect(check.problems.isEmpty)
        #expect(check.isAcceptable)
        #expect(check.suggestion == nil)
    }

    @Test func emptyCodeIsRejected() {
        #expect(advisor.check("").problems == [.empty])
        #expect(!advisor.check("").isAcceptable)
    }

    @Test func invalidCharactersAreListed() {
        let check = advisor.check("jaro 2026!")
        #expect(check.problems == [.invalidCharacters(" !")])
        #expect(!check.isAcceptable)
    }

    @Test func tooLongCodeIsRejected() {
        let long = String(repeating: "a", count: OfferCodeAdvisor.maxLength + 1)
        #expect(advisor.check(long).problems == [.tooLong(OfferCodeAdvisor.maxLength + 1)])
    }

    @Test func usedCodeIsRejectedWithSuggestion() {
        let check = advisor.check("spring_v3")
        #expect(check.problems == [.usedBefore])
        #expect(!check.isAcceptable)
        #expect(check.suggestion == "spring_v4")
    }

    @Test func caseVariantIsOnlyAWarning() {
        let check = advisor.check("winter")
        #expect(check.problems == [.caseVariantOf("Winter")])
        #expect(check.isAcceptable)
    }

    @Test func suggestionsFollowBaseVersionShape() {
        #expect(advisor.suggestion(for: "spring") == "spring_v4")
        #expect(advisor.suggestion(for: "summer") == "summer_v2")
        #expect(advisor.suggestion(for: "autumn") == "autumn_v1")
        #expect(advisor.suggestion(for: "Jaro 2026") == "Jaro_2026_v1")
        #expect(advisor.suggestion(for: "  ") == nil)
    }
}
