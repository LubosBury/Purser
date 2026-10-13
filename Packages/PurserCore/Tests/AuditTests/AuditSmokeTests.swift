import Testing
import PurserTestSupport
import Audit

/// Proves that the Audit module builds and links into a test target.
/// It does not use the module marker, so the marker can be deleted once the module has real sources.
@Test func auditModuleLinks() {
    #expect(PurserTestSupportModule.name == "PurserTestSupport")
}
