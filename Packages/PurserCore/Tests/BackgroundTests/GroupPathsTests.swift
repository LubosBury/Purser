import Foundation
import Testing
@testable import Background

@Suite struct GroupPathsTests {
    @Test func signedValuesPassAndUnsignedOrUnexpandedValuesAreRejected() {
        #expect(GroupPaths.normalized("ABCDE12345.com.lubosbury.purser") == "ABCDE12345.com.lubosbury.purser")
        #expect(GroupPaths.normalized(" ABCDE12345.com.lubosbury.purser.shared ") == "ABCDE12345.com.lubosbury.purser.shared")
        #expect(GroupPaths.normalized("com.lubosbury.purser") == nil)
        #expect(GroupPaths.normalized("$(TeamIdentifierPrefix)com.lubosbury.purser") == nil)
        #expect(GroupPaths.normalized("") == nil)
        #expect(GroupPaths.normalized(nil) == nil)
    }

    /// K2: the registry root inside the App Group container is the one M0's AppEnvironment uses.
    @Test func workspacesRootIsTheK2RegistryRoot() {
        let container = URL(fileURLWithPath: "/tmp/group-container", isDirectory: true)
        #expect(GroupPaths.workspacesRoot(inGroupContainer: container).path
                == "/tmp/group-container/Library/Application Support/Purser")
    }
}
