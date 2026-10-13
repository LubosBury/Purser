import Foundation

public enum OwnerError: Error, Equatable {
    case emptyName
}

/// The name this Mac's Purser writes into the audit as actor (spec D2), stored in the Keychain.
/// It labels the log; it is not an access check. Touch ID is.
public struct OwnerRegistry: Sendable {
    private let store: any SecretStore

    public init(store: SecretStore) {
        self.store = store
    }

    public func owner() throws -> String? {
        try store.get(account: SecretAccount.ownerName).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Stores the trimmed name and returns it. Also drops the Apple user id that builds with Sign in with Apple kept.
    @discardableResult
    public func setOwner(name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OwnerError.emptyName }
        try store.set(Data(trimmed.utf8), account: SecretAccount.ownerName)
        try store.delete(account: SecretAccount.legacyOwnerAppleUserId)
        return trimmed
    }
}
