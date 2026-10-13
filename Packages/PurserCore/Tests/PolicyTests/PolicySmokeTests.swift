import Testing
import PurserTestSupport
import Policy

/// Proves that the Policy module builds and links into a test target.
/// It does not use the module marker, so the marker can be deleted once the module has real sources.
@Test func policyModuleLinks() {
    #expect(PurserTestSupportModule.name == "PurserTestSupport")
}
