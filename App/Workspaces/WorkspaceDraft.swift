import Foundation
import Domain
import PurserSecurity

/// The "new workspace" form. The .p8 content lives only in memory here and then in the Keychain.
struct WorkspaceDraft {
    enum DraftError: Error, CustomStringConvertible {
        case notSignedIn
        case invalid([String])
        case keychain(String)

        var description: String {
            switch self {
            case .notSignedIn: return "Set the owner name first."
            case let .invalid(problems): return problems.joined(separator: " ")
            case let .keychain(message): return message
            }
        }
    }

    var name = ""
    var colorHex = "#2E7D32"
    var isProduction = false
    var appId = ""
    var bundleId = ""
    var keyKind: KeyKind = .team
    var keyId = ""
    var issuerId = ""
    var privateKeyPEM: String?
    var keyFileName: String?

    var identity: JWTIdentity {
        keyKind == .team ? .team(issuerId: issuerId.trimmingCharacters(in: .whitespaces)) : .individual
    }

    var problems: [String] {
        var problems = WorkspaceValidation.problems(name: name, colorHex: colorHex, appId: appId, bundleId: bundleId,
                                                    keyKind: keyKind, keyId: keyId,
                                                    issuerId: keyKind == .team ? issuerId : (issuerId.isEmpty ? nil : issuerId))
        if privateKeyPEM == nil { problems.append("Choose the .p8 key file.") }
        return problems
    }

    func config(id: UUID) -> WorkspaceConfig {
        WorkspaceConfig(id: id, name: name.trimmingCharacters(in: .whitespaces), colorHex: colorHex, isProduction: isProduction,
                        appId: appId, bundleId: bundleId, keyKind: keyKind, keyId: keyId,
                        issuerId: keyKind == .team ? issuerId.trimmingCharacters(in: .whitespaces) : nil,
                        importMapping: nil, googleClientId: nil, slackWebhookEnabled: false, nightlySyncHourUTC: 3)
    }

    /// Reads a .p8 picked in the file importer. The file is only read, never copied.
    static func readKeyFile(at url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
