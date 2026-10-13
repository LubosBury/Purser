import Foundation
import Domain

/// Spec §7 levels C0-C2. An empty result means the response may start writes.
public enum ConfirmationValidator {
    public static func problems(request: ConfirmationRequest, response: ConfirmationResponse) -> [String] {
        var problems: [String] = []
        if !response.accepted { problems.append("Confirmation was not accepted") }
        if !request.excluded.isEmpty, !response.acknowledgedExclusions {
            problems.append("C0: the \(request.excluded.count) excluded cells were not acknowledged")
        }
        if request.level >= .c1,
           response.typedAppName?.trimmingCharacters(in: .whitespacesAndNewlines) != request.appName {
            problems.append("C1: the typed app name does not match \(request.appName)")
        }
        if request.level >= .c2 {
            let reason = response.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if reason.count < AppleConstants.c2MinReasonLength {
                problems.append("C2: the reason must have at least \(AppleConstants.c2MinReasonLength) characters")
            }
            let missing = Set(request.riskClasses.keys).subtracting(response.checkedRiskClasses)
            if !missing.isEmpty { problems.append("C2: unchecked risk classes: \(missing.sorted().joined(separator: ", "))") }
        }
        return problems
    }
}
