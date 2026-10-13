import Testing
import PurserTestSupport
import Catalog

/// Proves that the Catalog module builds and links into a test target.
/// It does not use the module marker, so the marker can be deleted once the module has real sources.
@Test func catalogModuleLinks() {
    #expect(PurserTestSupportModule.name == "PurserTestSupport")
}
