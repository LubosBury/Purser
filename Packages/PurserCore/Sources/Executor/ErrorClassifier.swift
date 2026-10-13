import Foundation
import ASCClient

/// Spec §6 signal table, one class per row.
package enum WriteErrorClass: Hashable, Sendable {
    case maybeApplied
    case notSent
    case rateLimited
    case serverError(Int)
    case unauthorized
    case agreement
    case forbidden
    case mustDeleteFuture
    case onlyFutureDeletable
    case conflict(Int)
    case refused
}

package enum ErrorClassifier {
    /// Phrases matched in code/title/detail. Spikes S6 and S8 confirm them against recorded ASC errors (SpikeFixtureTests).
    package static let pricingNotAllowedPhrase = "Pricing change is not allowed"
    package static let mustDeletePhrase = "Must delete future price change"
    package static let onlyFuturePhrase = "Only future price changes can be deleted"
    package static let agreementCodeFragment = "REQUIRED_AGREEMENTS"

    package static func classify(_ error: ASCError) -> WriteErrorClass {
        switch error {
        case .rateLimited:
            return .rateLimited
        case let .network(_, maybeSent):
            return maybeSent ? .maybeApplied : .notSent
        case .decoding:
            return .maybeApplied
        case .foreignResource, .readOnlyClient:
            return .refused
        case let .http(status, code, title, detail):
            let text = [code, title, detail].compactMap { $0 }.joined(separator: " ")
            switch status {
            case 401: return .unauthorized
            case 403: return text.contains(agreementCodeFragment) ? .agreement : .forbidden
            case 409 where text.contains(pricingNotAllowedPhrase): return .agreement
            case 409 where text.contains(mustDeletePhrase): return .mustDeleteFuture
            case 409 where text.contains(onlyFuturePhrase): return .onlyFutureDeletable
            case 429: return .rateLimited
            case 500...599: return .serverError(status)
            default: return .conflict(status)
            }
        }
    }
}
