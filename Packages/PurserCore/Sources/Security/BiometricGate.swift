import Foundation
import LocalAuthentication

public protocol BiometricGate: Sendable {
    /// Touch ID with fallback to the Mac password (LAPolicy.deviceOwnerAuthentication).
    func authenticate(reason: String) async throws
}

public enum BiometricError: Error, Equatable, Sendable {
    case notAuthenticated
}

public struct LocalAuthenticationGate: BiometricGate {
    public init() {}

    public func authenticate(reason: String) async throws {
        let context = LAContext()
        let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        guard success else { throw BiometricError.notAuthenticated }
    }
}

/// Tests and previews only.
public struct AlwaysAllowGate: BiometricGate {
    public init() {}
    public func authenticate(reason: String) async throws {}
}
