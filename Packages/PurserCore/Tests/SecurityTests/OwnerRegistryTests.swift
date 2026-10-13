import Foundation
import Testing
import PurserSecurity

@Suite struct OwnerRegistryTests {
    @Test func storesTheTrimmedNameAndReplacesItOnRename() throws {
        let store = InMemorySecretStore()
        let registry = OwnerRegistry(store: store)
        #expect(try registry.owner() == nil)
        #expect(try registry.setOwner(name: "  Synthetic Owner \n") == "Synthetic Owner")
        #expect(try registry.owner() == "Synthetic Owner")
        #expect(try store.get(account: SecretAccount.ownerName) == Data("Synthetic Owner".utf8))
        try registry.setOwner(name: "Renamed Owner")
        #expect(try registry.owner() == "Renamed Owner")
    }

    @Test(arguments: ["", "   ", "\n\t"])
    func rejectsAnEmptyNameAndKeepsThePreviousOne(name: String) throws {
        let registry = OwnerRegistry(store: InMemorySecretStore())
        try registry.setOwner(name: "Synthetic Owner")
        #expect(throws: OwnerError.emptyName) { try registry.setOwner(name: name) }
        #expect(try registry.owner() == "Synthetic Owner")
    }

    /// An install that signed in with Apple has only the old item: it counts as no owner, and naming one removes it.
    @Test func ignoresAndRemovesTheLegacyAppleUserId() throws {
        let store = InMemorySecretStore()
        try store.set(Data("001234.synthetic-owner.0001".utf8), account: SecretAccount.legacyOwnerAppleUserId)
        let registry = OwnerRegistry(store: store)
        #expect(try registry.owner() == nil)
        try registry.setOwner(name: "Synthetic Owner")
        #expect(try store.get(account: SecretAccount.legacyOwnerAppleUserId) == nil)
    }
}
