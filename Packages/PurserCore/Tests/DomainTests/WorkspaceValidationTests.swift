import Testing
import Domain

@Suite struct WorkspaceValidationTests {
    @Test func acceptsAValidTeamKeyWorkspace() {
        #expect(WorkspaceValidation.problems(name: "Fruit Journal", colorHex: "#2E7D32", appId: "6400000001",
                                             bundleId: "com.example.fruitjournal", keyKind: .team, keyId: "ABCDEF1234",
                                             issuerId: "69a6de70-0000-47e3-e053-5b8c7c11a4d1").isEmpty)
    }

    @Test func acceptsAValidIndividualKeyWorkspace() {
        #expect(WorkspaceValidation.problems(name: "Fruit Journal", colorHex: "#c62828", appId: "6400000001",
                                             bundleId: "com.example.fruit-journal", keyKind: .individual, keyId: "ZYXWVU9876",
                                             issuerId: nil).isEmpty)
    }

    @Test func reportsEveryProblem() {
        let problems = WorkspaceValidation.problems(name: "  ", colorHex: "green", appId: "app-1", bundleId: "fruit",
                                                    keyKind: .team, keyId: "abc", issuerId: "")
        #expect(problems.count == 6)
    }

    @Test func individualKeysMustNotCarryAnIssuer() {
        let problems = WorkspaceValidation.problems(name: "Fruit Journal", colorHex: "#2E7D32", appId: "6400000001",
                                                    bundleId: "com.example.fruitjournal", keyKind: .individual, keyId: "ABCDEF1234",
                                                    issuerId: "69a6de70-0000-47e3-e053-5b8c7c11a4d1")
        #expect(problems == ["An individual key has no Issuer ID; leave the field empty."])
    }
}
