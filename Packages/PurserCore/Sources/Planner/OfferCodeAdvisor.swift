import Foundation

public enum OfferCodeProblem: Hashable, Sendable {
    case empty
    case tooLong(Int)
    case invalidCharacters(String)
    case usedBefore
    case caseVariantOf(String)
}

public struct OfferCodeCheck: Hashable, Sendable {
    public var code: String
    public var problems: [OfferCodeProblem]
    public var suggestion: String?

    public init(code: String, problems: [OfferCodeProblem], suggestion: String?) {
        self.code = code; self.problems = problems; self.suggestion = suggestion
    }

    /// Only a case variant of a used code is a warning (codes are case-sensitive, O1); everything else blocks.
    public var isAcceptable: Bool {
        problems.allSatisfy { problem in
            if case .caseVariantOf = problem { return true }
            return false
        }
    }
}

/// Rule O1 while typing: a code must never have appeared in this workspace (offer_code_registry),
/// and Purser proposes the shape `<base>_v<n>`.
public struct OfferCodeAdvisor: Sendable {
    /// Purser's own conservative limits; Apple documents no exact charset (spike S7 records rejections).
    public static let maxLength = 64
    static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")

    public let registry: Set<String>

    public init(registry: Set<String>) { self.registry = registry }

    public func check(_ code: String) -> OfferCodeCheck {
        if code.isEmpty { return OfferCodeCheck(code: code, problems: [.empty], suggestion: nil) }
        var problems: [OfferCodeProblem] = []
        if code.count > Self.maxLength { problems.append(.tooLong(code.count)) }
        var bad = String.UnicodeScalarView()
        for scalar in code.unicodeScalars where !Self.allowed.contains(scalar) { bad.append(scalar) }
        if !bad.isEmpty { problems.append(.invalidCharacters(String(bad))) }
        if registry.contains(code) {
            problems.append(.usedBefore)
        } else if let variant = registry.sorted().first(where: { $0.lowercased() == code.lowercased() }) {
            problems.append(.caseVariantOf(variant))
        }
        let suggestion = registry.contains(code) ? suggestion(for: code) : nil
        return OfferCodeCheck(code: code, problems: problems, suggestion: suggestion)
    }

    /// `<base>_v<n>` with n one higher than any used version of the base (2 when only the bare base was used).
    public func suggestion(for input: String) -> String? {
        let base = Self.base(of: Self.sanitize(input))
        guard !base.isEmpty else { return nil }
        let versions = registry.filter { Self.base(of: $0) == base }.compactMap { Self.version(of: $0) }
        var n = (versions.max() ?? (registry.contains(base) ? 1 : 0)) + 1
        while registry.contains("\(base)_v\(n)") { n += 1 }
        return "\(base)_v\(n)"
    }

    static func sanitize(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = String.UnicodeScalarView()
        for scalar in trimmed.unicodeScalars { out.append(allowed.contains(scalar) ? scalar : "_") }
        return String(out)
    }

    static func base(of code: String) -> String {
        if let match = code.firstMatch(of: #/_v(\d+)$/#) { return String(code[..<match.range.lowerBound]) }
        return code
    }

    static func version(of code: String) -> Int? {
        guard let match = code.firstMatch(of: #/_v(\d+)$/#) else { return nil }
        return Int(match.1)
    }
}
