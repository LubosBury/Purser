import Testing
import MCPBridge

@Suite struct LocalizationToolCatalogTests {
    @Test func createLocalizationPlanIsALocalToolThatNeedsRows() throws {
        let tool = try #require(ToolCatalog.definition(named: "create_localization_plan"))
        #expect(tool.access == .local)
        #expect(tool.inputSchema["required"] == ["rows"])
        let row = try #require(tool.inputSchema["properties"]?["rows"]?["items"])
        #expect(row["required"] == ["product", "locale"])
        #expect(row["properties"]?["custom_app_name"] != nil)
        #expect(tool.description.contains("Nothing is written until apply_plan"))
    }
}
