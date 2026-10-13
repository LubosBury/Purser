import Testing
import PurserTestSupport
import Store

/// Proves that the Store module builds and links into a test target.
/// It does not use the module marker, so the marker can be deleted once the module has real sources.
@Test func storeModuleLinks() {
    #expect(PurserTestSupportModule.name == "PurserTestSupport")
}
