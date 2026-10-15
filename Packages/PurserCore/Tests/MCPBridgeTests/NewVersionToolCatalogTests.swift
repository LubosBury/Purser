import Testing
import MCPBridge

@Suite struct NewVersionToolCatalogTests {
    @Test func createLocalizationPlanSaysItCreatesAVersionForAnApprovedProduct() throws {
        let tool = try #require(ToolCatalog.definition(named: "create_localization_plan"))
        #expect(tool.description.contains("the plan first creates a new version (rule N5, confirmation C1)"))
        #expect(!tool.description.contains("is blocked (N5)"))
    }
}
