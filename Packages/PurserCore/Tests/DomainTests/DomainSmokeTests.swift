import Testing
import PurserTestSupport
import Domain

/// Proves that the Domain module builds and links into a test target.
/// It does not use the module marker, so the marker can be deleted once the module has real sources.
@Test func domainModuleLinks() {
    #expect(PurserTestSupportModule.name == "PurserTestSupport")
}
