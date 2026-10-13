import Foundation

/// Checks of the "new workspace" form. Pure, so the SwiftUI form stays thin and the rules are tested.
public enum WorkspaceValidation {
    public static func problems(name: String, colorHex: String, appId: String, bundleId: String,
                                keyKind: KeyKind, keyId: String, issuerId: String?) -> [String] {
        var problems: [String] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append("The name must not be empty.")
        }
        if colorHex.wholeMatch(of: /#[0-9A-Fa-f]{6}/) == nil {
            problems.append("The color must have the form #RRGGBB.")
        }
        if appId.isEmpty || appId.wholeMatch(of: /[0-9]+/) == nil {
            problems.append("The App ID is a number from App Store Connect (App Information → Apple ID).")
        }
        if bundleId.wholeMatch(of: /[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+/) == nil {
            problems.append("The bundle ID has the form com.company.app.")
        }
        if keyId.wholeMatch(of: /[A-Z0-9]{10}/) == nil {
            problems.append("The Key ID has 10 characters (capital letters and digits).")
        }
        let issuer = issuerId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch keyKind {
        case .team where UUID(uuidString: issuer) == nil:
            problems.append("A team key needs an Issuer ID in UUID form.")
        case .individual where !issuer.isEmpty:
            problems.append("An individual key has no Issuer ID; leave the field empty.")
        default:
            break
        }
        return problems
    }
}
