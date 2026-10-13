import Testing
import PurserTestSupport
import ASCClient

/// Proves that the ASCClient module builds and links into a test target.
/// It does not use the module marker, so the marker can be deleted once the module has real sources.
@Test func ascClientModuleLinks() {
    #expect(PurserTestSupportModule.name == "PurserTestSupport")
}
