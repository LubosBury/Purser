#if DEBUG
import SwiftUI

/// Debug-only menu for spikes. Never part of a Release build.
struct DebugCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Debug") {
            Button("Keychain self-test (spike SK)") { model.runKeychainSelfTest() }
            Button("Discard the local price point cache (spike S0)") { model.dropPricePointCache() }
        }
    }
}

extension AppModel {
    /// Writes, reads and deletes a throwaway Keychain item with the app's access group and reports the outcome.
    func runKeychainSelfTest() {
        let account = "purser.sk-selftest"
        let payload = Data(UUID().uuidString.utf8)
        let group = environment.keychainAccessGroup ?? "(default group)"
        do {
            try environment.secretStore.set(payload, account: account)
            let back = try environment.secretStore.get(account: account)
            try environment.secretStore.delete(account: account)
            let gone = try environment.secretStore.get(account: account) == nil
            errorMessage = "SK self-test: write/read \(back == payload ? "OK" : "MISMATCH"), delete \(gone ? "OK" : "FAILED"); access group \(group)."
        } catch {
            errorMessage = "SK self-test failed: \(error); access group \(group)."
        }
    }

    /// Empties the local price point cache of the open workspace so the next sync reads every point again
    /// (cold-sync measurement in spike S0). Touches only the local cache, never ASC.
    func dropPricePointCache() {
        guard case let .open(session) = phase else {
            errorMessage = "Open a workspace first."
            return
        }
        do {
            let removed = try session.database.writer.write { db -> Int in
                try db.execute(sql: "DELETE FROM price_point")
                return db.changesCount
            }
            errorMessage = "Deleted \(removed) price points from the local cache; the next sync loads them again."
        } catch {
            errorMessage = "The cache cannot be deleted: \(error)"
        }
    }
}
#endif
