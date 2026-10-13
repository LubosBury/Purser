import Foundation

/// Per-request context the caller sets around one ASC call (package-internal, contract change request 1 of M2).
package enum ASCRequestContext {
    /// The `jti` the caller already wrote into its HTTP_SENT audit event; ASCHTTPClient puts it into the request's token.
    /// nil = a fresh random UUID per request.
    @TaskLocal package static var tokenId: String?
}
