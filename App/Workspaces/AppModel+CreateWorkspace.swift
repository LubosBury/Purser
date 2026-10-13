import Foundation
import Domain
import PurserSecurity
import Store

extension AppModel {
    /// Creates the registry entry, the workspace database with its config, and stores the .p8 in the Keychain.
    func createWorkspace(_ draft: WorkspaceDraft) async throws {
        guard let auditActor else { throw WorkspaceDraft.DraftError.notSignedIn }
        let problems = draft.problems
        guard problems.isEmpty, let pem = draft.privateKeyPEM else { throw WorkspaceDraft.DraftError.invalid(problems) }
        _ = try JWTSigner(keyId: draft.keyId, identity: draft.identity, privateKeyPEM: pem)
        try await authenticateUnlessRecent(reason: "create the workspace and save the key to the Keychain")

        let entry = try registry.create(name: draft.name.trimmingCharacters(in: .whitespaces), colorHex: draft.colorHex)
        let config = draft.config(id: entry.id)
        let database = try WorkspaceDatabase.open(at: registry.directory(for: entry))
        let audit = AuditLogFactory.make(database: database, owner: auditActor)
        try await database.writer.write { db in
            try WorkspaceConfigStore(database: database).save(config, at: Date(), in: db)
            try audit.append(.configChanged, refs: ["workspace": entry.id.uuidString], payload: ConfigChangePayload(action: "created", before: nil, after: config), in: db)
        }
        reloadWorkspaces()
        do {
            try environment.secretStore.set(Data(pem.utf8), account: SecretAccount.ascPrivateKey(entry.id))
        } catch {
            throw WorkspaceDraft.DraftError.keychain("The workspace is created, but the key could not be saved to the Keychain (\(error)). Import the .p8 again in Settings.")
        }
    }
}
