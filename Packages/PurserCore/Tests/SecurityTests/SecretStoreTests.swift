import Foundation
import Testing
import PurserSecurity

@Suite struct SecretStoreTests {
    @Test func inMemoryStoreSetsGetsAndDeletes() throws {
        let store = InMemorySecretStore()
        let account = SecretAccount.ascPrivateKey(UUID(uuidString: "11111111-2222-4333-8444-555555555555")!)
        #expect(account == "asc-key.11111111-2222-4333-8444-555555555555")
        #expect(try store.get(account: account) == nil)
        try store.set(Data("one".utf8), account: account)
        try store.set(Data("two".utf8), account: account)
        #expect(try store.get(account: account) == Data("two".utf8))
        try store.delete(account: account)
        try store.delete(account: account)
        #expect(try store.get(account: account) == nil)
    }

    @Test func accountsAreScopedPerWorkspace() {
        let a = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let b = UUID(uuidString: "99999999-2222-4333-8444-555555555555")!
        #expect(SecretAccount.ascPrivateKey(a) != SecretAccount.ascPrivateKey(b))
        #expect(SecretAccount.googleToken(a) == "google-token.11111111-2222-4333-8444-555555555555")
        #expect(SecretAccount.slackWebhook(b) == "slack-webhook.99999999-2222-4333-8444-555555555555")
    }

    @Test func alwaysAllowGateNeverThrows() async throws {
        try await AlwaysAllowGate().authenticate(reason: "test")
    }
}
