import Foundation
import Domain
import ASCClient

public enum FakeFault: Hashable, Sendable {
    case rateLimited
    case serverError(status: Int, applyFirst: Bool)
    case timeoutAfterApply
    case networkBeforeSend
    case pricingNotAllowed
    case agreementMissing403
    case unauthorized
    case conflict(code: String, detail: String)
}

public enum FakeMatch: Hashable, Sendable {
    case any, writes, reads
    case method(String)
    case pathPrefix(String)
}

public struct FakeRequestRecord: Hashable, Sendable {
    public var index: Int
    public var method: String
    public var path: String
    public var query: [String: String]
    public var body: Data?
    public var status: Int?               // nil when a transport error was thrown
    public var applied: Bool              // the request changed the model
    public var hadAuthorization: Bool     // only presence is recorded, never the value
    public var identity: String?          // "team" or "individual" when the token shape was accepted
    public var tokenId: String?           // the accepted token's jti (never the token itself)
    public var host: String = FakeASC.apiHost
    public var isWrite: Bool { method != "GET" }
}

/// Spec §9: FakeASC accepts both ASC token shapes. ES256 with a kid, aud appstoreconnect-v1, lifetime 1-1200 s and either
/// a non-empty "iss" without "sub" (team key) or "sub": "user" without "iss" (individual key). The signature is not checked.
enum FakeJWT {
    struct Accepted: Sendable {
        let identity: String
        let tokenId: String?
    }

    static func validate(_ authorization: String?) -> Accepted? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let parts = authorization.dropFirst("Bearer ".count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[2].isEmpty,
              let header = object(parts[0]), let claims = object(parts[1]),
              header["alg"] as? String == "ES256", let kid = header["kid"] as? String, !kid.isEmpty,
              claims["aud"] as? String == "appstoreconnect-v1",
              let issuedAt = claims["iat"] as? Int, let expiresAt = claims["exp"] as? Int,
              expiresAt > issuedAt, expiresAt - issuedAt <= 1200 else { return nil }
        let tokenId = claims["jti"] as? String
        if let issuer = claims["iss"] as? String, !issuer.isEmpty, claims["sub"] == nil {
            return Accepted(identity: "team", tokenId: tokenId)
        }
        if claims["iss"] == nil, claims["sub"] as? String == "user" {
            return Accepted(identity: "individual", tokenId: tokenId)
        }
        return nil
    }

    static func object(_ segment: Substring) -> [String: Any]? {
        var text = segment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        guard let data = Data(base64Encoded: text) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

struct FakeReply: Sendable {
    var status: Int
    var body: JSONBody?
    var applied: Bool
}

struct FakeRejection: Error { let reply: FakeReply }

/// In-memory App Store Connect behind HTTPTransport. Semantics are documented in the M2 plan, Task 2.2.
public actor FakeASC: HTTPTransport {
    /// Internal setter: FakeASC+Writes.swift (another file of the same module) mutates the model.
    public internal(set) var model: FakeModel
    let now: @Sendable () -> Date
    var rateLimit: Int
    var rateRemaining: Int
    var appleDeleteCutoffHours = AppleConstants.replaceCutoffHours
    /// Spike S10: whether ASC answers a manual IAP price sent with `startDate: null` with the creation day.
    var iapNullStartEchoesCreationDay = false
    /// Whether a new version copies the Live version's localizations under new ids (an assumption until a live trial of a
    /// new version of an approved product shows it).
    var newVersionCopiesLocalizations = true
    var faults: [(match: FakeMatch, fault: FakeFault, remaining: Int)] = []
    var log: [FakeRequestRecord] = []
    var counter = 0
    /// Bytes per upload operation of a screenshot reservation.
    var uploadPartSize = 1_048_576

    public init(model: FakeModel, now: @escaping @Sendable () -> Date, rateLimit: Int = 3600) {
        self.model = model
        self.now = now
        self.rateLimit = rateLimit
        self.rateRemaining = rateLimit
    }

    public func mutate(_ change: @Sendable (inout FakeModel) -> Void) { change(&model) }
    public func inject(_ fault: FakeFault, times: Int = 1, matching: FakeMatch = .writes) { faults.append((matching, fault, times)) }
    public func clearFaults() { faults.removeAll() }
    public func setRateBudget(limit: Int, remaining: Int) { rateLimit = limit; rateRemaining = remaining }
    public func setAppleDeleteCutoffHours(_ hours: Int) { appleDeleteCutoffHours = hours }
    public func setIAPNullStartEchoesCreationDay(_ on: Bool) { iapNullStartEchoesCreationDay = on }
    public func setNewVersionCopiesLocalizations(_ on: Bool) { newVersionCopiesLocalizations = on }
    public func requests() -> [FakeRequestRecord] { log }
    public func writeRequests() -> [FakeRequestRecord] { log.filter(\.isWrite) }
    public func setUploadPartSize(_ bytes: Int) { uploadPartSize = bytes }
    /// Requests to Apple's upload and image hosts (cloning).
    public func assetRequests() -> [FakeRequestRecord] { log.filter { $0.host != Self.apiHost } }

    /// Rows that share a natural key inside one cell (must always be empty after any Purser run).
    public func duplicates() -> [String] {
        var seen = Set<String>()
        var duplicated: [String] = []
        func check(_ key: String) { if !seen.insert(key).inserted { duplicated.append(key) } }
        for r in model.regularPrices {
            check("R|\(r.subscriptionId)|\(r.territory)|\(r.planType.rawValue)|\(r.startDate?.iso ?? "-")|\(r.pricePointId)")
        }
        for i in model.intros {
            check("I|\(i.subscriptionId)|\(i.territory)|\(i.planType.rawValue)|\(i.mode.rawValue)|\(i.duration.rawValue)|\(i.pricePointId ?? "-")|\(i.effectiveStart.iso)")
        }
        for p in model.promos { check("P|\(p.offerCode)") }
        return duplicated
    }

    var today: CalendarDate { CalendarDate.today(now: now()) }

    func nextId(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)-n\(counter)"
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET"
        guard let url = request.url else { throw URLError(.badURL) }
        var query: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let authorization = request.value(forHTTPHeaderField: "Authorization")
        var record = FakeRequestRecord(index: log.count, method: method, path: url.path, query: query, body: request.httpBody,
                                       status: nil, applied: false, hadAuthorization: authorization?.hasPrefix("Bearer ") == true,
                                       identity: nil, tokenId: nil, host: url.host ?? "")
        // Apple's upload and image hosts take no JWT (FakeASC+Products.swift).
        if record.host != Self.apiHost { return try assetExchange(&record, url: url, body: request.httpBody) }
        let fault = takeFault(method: method, path: url.path)
        if fault == .networkBeforeSend {
            log.append(record)
            throw URLError(.notConnectedToInternet)
        }
        guard let token = FakeJWT.validate(authorization) else {
            return finish(&record, url: url, reply: error(401, code: "NOT_AUTHORIZED", title: "Authentication credentials are missing or invalid.",
                                                         detail: "Provide a properly configured and signed bearer token, and make sure that it has not expired."))
        }
        record.identity = token.identity
        record.tokenId = token.tokenId
        guard rateRemaining > 0 else {
            return finish(&record, url: url, reply: error(429, code: "RATE_LIMIT_EXCEEDED", title: "The API rate limit was exceeded.", detail: "Rate limit exceeded"))
        }
        rateRemaining -= 1
        if let fault, let early = earlyReply(for: fault, isWrite: method != "GET") {
            return finish(&record, url: url, reply: early)
        }
        var reply: FakeReply
        do {
            reply = method == "GET" ? try handleRead(url: url, query: query) : try handleWrite(method: method, path: url.path, body: request.httpBody)
        } catch let rejection as FakeRejection {
            reply = rejection.reply
        }
        if case let .serverError(status, true)? = fault {
            reply = FakeReply(status: status, body: errorBody(status, code: "UNEXPECTED_ERROR", title: "Server error", detail: "Injected"), applied: reply.applied)
        }
        if fault == .timeoutAfterApply {
            record.applied = reply.applied
            log.append(record)
            throw URLError(.timedOut)
        }
        return finish(&record, url: url, reply: reply)
    }

    func takeFault(method: String, path: String) -> FakeFault? {
        for index in faults.indices where faults[index].remaining > 0 {
            let matches: Bool
            switch faults[index].match {
            case .any: matches = true
            case .writes: matches = method != "GET"
            case .reads: matches = method == "GET"
            case let .method(m): matches = method == m
            case let .pathPrefix(prefix): matches = path.hasPrefix(prefix)
            }
            if matches {
                faults[index].remaining -= 1
                return faults[index].fault
            }
        }
        return nil
    }

    func earlyReply(for fault: FakeFault, isWrite: Bool) -> FakeReply? {
        switch fault {
        case .rateLimited:
            return error(429, code: "RATE_LIMIT_EXCEEDED", title: "The API rate limit was exceeded.", detail: "Injected 429")
        case .unauthorized:
            return error(401, code: "NOT_AUTHORIZED", title: "Authentication credentials are missing or invalid.", detail: "Injected 401")
        case .agreementMissing403:
            return error(403, code: "FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED", title: "A required agreement is missing or has expired.",
                         detail: "This request requires an in-effect agreement that has not been signed or has expired.")
        case .pricingNotAllowed where isWrite:
            return error(409, code: "ENTITY_ERROR", title: "The request entity is not valid.", detail: "Pricing change is not allowed")
        case let .conflict(code, detail):
            return error(409, code: code, title: "The request entity is not valid.", detail: detail)
        case let .serverError(status, false):
            return error(status, code: "UNEXPECTED_ERROR", title: "Server error", detail: "Injected")
        default:
            return nil
        }
    }

    func finish(_ record: inout FakeRequestRecord, url: URL, reply: FakeReply) -> (Data, HTTPURLResponse) {
        record.status = reply.status
        record.applied = reply.applied
        log.append(record)
        let data = (try? reply.body?.data()) ?? Data()
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": "application/json",
            "X-Rate-Limit": "user-hour-lim:\(rateLimit);user-hour-rem:\(max(rateRemaining, 0));",
        ])!
        return (data, response)
    }

    func errorBody(_ status: Int, code: String, title: String, detail: String) -> JSONBody {
        .object(["errors": .array([.object([
            "id": .string(UUID().uuidString), "status": .string(String(status)), "code": .string(code),
            "title": .string(title), "detail": .string(detail),
        ])])])
    }

    func error(_ status: Int, code: String, title: String, detail: String) -> FakeReply {
        FakeReply(status: status, body: errorBody(status, code: code, title: title, detail: detail), applied: false)
    }

    func conflict(_ code: String, _ detail: String) -> FakeRejection {
        FakeRejection(reply: error(409, code: code, title: "The request entity is not valid.", detail: detail))
    }

    func notFound() -> FakeRejection {
        FakeRejection(reply: error(404, code: "NOT_FOUND", title: "The specified resource does not exist", detail: "Not found"))
    }

    /// Matches path components against a pattern; "*" captures one component. Returns the capture ("" if none).
    func capture(_ components: [String], _ pattern: [String]) -> String? {
        guard components.count == pattern.count else { return nil }
        var captured = ""
        for (component, part) in zip(components, pattern) {
            if part == "*" { captured = component } else if component != part { return nil }
        }
        return captured
    }

    func components(_ path: String) -> [String] { path.split(separator: "/").map(String.init) }
}
