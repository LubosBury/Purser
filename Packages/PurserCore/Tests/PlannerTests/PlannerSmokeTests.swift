import Testing
import PurserTestSupport
import Planner

/// Proves that the Planner module builds and links into a test target.
/// It does not use the module marker, so the marker can be deleted once the module has real sources.
@Test func plannerModuleLinks() {
    #expect(PurserTestSupportModule.name == "PurserTestSupport")
}
