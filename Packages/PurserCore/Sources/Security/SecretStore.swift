import Foundation
import Security

public protocol SecretStore: Sendable {
    func set(_ data: Data, account: String) throws
    func get(account: String) throws -> Data?
    func delete(account: String) throws
}

public enum SecretStoreError: Error, Equatable, Sendable {
    /// A Keychain call failed with this OSStatus (e.g. -34018 errSecMissingEntitlement in an unsigned build).
    case keychain(status: Int32)
}

/// kSecClassGenericPassword, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, service "com.lubosbury.purser".
/// Uses the data protection keychain, so the access group comes from the keychain-access-groups entitlement.
public struct KeychainSecretStore: SecretStore {
    private let service: String
    private let accessGroup: String?

    public init(service: String = "com.lubosbury.purser", accessGroup: String?) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func set(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status: status) }
    }

    public func get(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status: status) }
        return result as? Data
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.keychain(status: status) }
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}

/// Test and preview store. Never used for real keys.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init() {}

    public func set(_ data: Data, account: String) throws {
        lock.withLock { items[account] = data }
    }

    public func get(account: String) throws -> Data? {
        lock.withLock { items[account] }
    }

    public func delete(account: String) throws {
        lock.withLock { _ = items.removeValue(forKey: account) }
    }
}

public enum SecretAccount {
    public static func ascPrivateKey(_ workspace: UUID) -> String { "asc-key.\(workspace.uuidString)" }
    public static func googleToken(_ workspace: UUID) -> String { "google-token.\(workspace.uuidString)" }
    public static func slackWebhook(_ workspace: UUID) -> String { "slack-webhook.\(workspace.uuidString)" }
    public static let ownerName = "owner.name"
    /// Written by builds that used Sign in with Apple; only ever deleted now.
    public static let legacyOwnerAppleUserId = "owner.apple-user-id"
}
