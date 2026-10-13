import Testing
import PurserTestSupport
import Importer

/// Proves that the Importer module builds and links into a test target.
/// It does not use the module marker, so the marker can be deleted once the module has real sources.
@Test func importerModuleLinks() {
    #expect(PurserTestSupportModule.name == "PurserTestSupport")
}
