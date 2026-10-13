import Foundation
import os
import Audit
import Domain
import Store

/// The owner's name as the audit writes it. The app has one; every AuditLog reads it when it appends, so a rename in
/// Settings reaches the open workspace's log.
final class AuditActor: Sendable {
    private let stored: OSAllocatedUnfairLock<String>

    init(_ name: String) {
        stored = OSAllocatedUnfairLock(initialState: name)
    }

    var name: String {
        get { stored.withLock { $0 } }
        set { stored.withLock { $0 = newValue } }
    }
}

enum AuditLogFactory {
    /// Every event carries the owner's name as actor.
    static func make(database: WorkspaceDatabase, owner: AuditActor) -> AuditLog {
        AuditLog(database: database, actor: { owner.name }, now: { Date() })
    }
}

/// configChanged payload. WorkspaceConfig holds no secrets; key material never goes here.
struct ConfigChangePayload: Encodable {
    var action: String
    var before: WorkspaceConfig?
    var after: WorkspaceConfig
}

struct SessionOpenedPayload: Encodable {
    var workspaceName: String
    /// Always false since the Apple ID check went; kept so old and new events have the same shape.
    var offline = false
    var appVersion: String
}

struct KeyImportedPayload: Encodable {
    var keyKind: String
    var keyId: String
}

struct ExportPayload: Encodable {
    var fileName: String
    var events: Int
    var headSeq: Int64?
    var headHash: String?
}

enum AppBuild {
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
