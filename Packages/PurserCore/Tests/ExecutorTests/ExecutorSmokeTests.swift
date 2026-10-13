import Testing
import PurserTestSupport
import Executor

/// Proves that the Executor module builds and links into a test target.
/// It does not use the module marker, so the marker can be deleted once the module has real sources.
@Test func executorModuleLinks() {
    #expect(PurserTestSupportModule.name == "PurserTestSupport")
}
