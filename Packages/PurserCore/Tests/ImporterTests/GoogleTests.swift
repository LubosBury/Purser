import Foundation
import Testing
import Importer
import PurserTestSupport

@Suite struct GoogleOAuthTests {
    @Test func challengeMatchesRFC7636AppendixB() {
        #expect(GoogleOAuth.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func verifierIsUnreservedAnd43Characters() {
        let a = GoogleOAuth.makeVerifier()
        let b = GoogleOAuth.makeVerifier()
        #expect(a.count == 43)
        #expect(a != b)
        #expect(a.wholeMatch(of: /[A-Za-z0-9\-._~]+/) != nil)
    }

    @Test func redirectUsesReversedClientId() {
        let id = "123-abc.apps.googleusercontent.com"
        #expect(GoogleOAuth.reversedClientId(id) == "com.googleusercontent.apps.123-abc")
        #expect(GoogleOAuth.redirectURI(clientId: id) == "com.googleusercontent.apps.123-abc:/oauth2redirect")
    }

    @Test func authorizationURLCarriesPKCEAndReadOnlyScope() throws {
        let url = GoogleOAuth.authorizationURL(clientId: "cid", redirectURI: "r:/cb", challenge: "ch", state: "st")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let q = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(url.host == "accounts.google.com")
        #expect(q["client_id"] == "cid")
        #expect(q["redirect_uri"] == "r:/cb")
        #expect(q["response_type"] == "code")
        #expect(q["scope"] == "https://www.googleapis.com/auth/spreadsheets.readonly")
        #expect(q["code_challenge"] == "ch")
        #expect(q["code_challenge_method"] == "S256")
        #expect(q["state"] == "st")
    }

    @Test func tokenAndRefreshRequestsAreFormPosts() throws {
        let token = GoogleOAuth.tokenRequest(clientId: "cid", redirectURI: "com.x:/oauth2redirect", code: "4/a+b", verifier: "ver")
        #expect(token.httpMethod == "POST")
        #expect(token.url?.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(token.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let body = String(decoding: try #require(token.httpBody), as: UTF8.self)
        #expect(body == "client_id=cid&code=4%2Fa%2Bb&code_verifier=ver&grant_type=authorization_code&redirect_uri=com.x%3A%2Foauth2redirect")
        let refresh = GoogleOAuth.refreshRequest(clientId: "cid", refreshToken: "1//r")
        #expect(String(decoding: try #require(refresh.httpBody), as: UTF8.self) == "client_id=cid&grant_type=refresh_token&refresh_token=1%2F%2Fr")
    }

    @Test func callbackParsingChecksState() throws {
        let ok = URL(string: "com.x:/oauth2redirect?state=s1&code=abc")!
        #expect(try GoogleOAuth.authorizationCode(from: ok, expectedState: "s1") == "abc")
        #expect(throws: GoogleOAuthError.stateMismatch) { try GoogleOAuth.authorizationCode(from: ok, expectedState: "s2") }
        #expect(throws: GoogleOAuthError.authorizationDenied("access_denied")) {
            try GoogleOAuth.authorizationCode(from: URL(string: "com.x:/oauth2redirect?error=access_denied&state=s1")!, expectedState: "s1")
        }
    }

    @Test func tokenResponseParsing() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let body = Data(#"{"access_token":"ya29.x","expires_in":3599,"refresh_token":"1//r","scope":"s","token_type":"Bearer"}"#.utf8)
        let token = try GoogleOAuth.parseTokenResponse(data: body, status: 200, now: now, previousRefreshToken: nil)
        #expect(token == GoogleToken(accessToken: "ya29.x", refreshToken: "1//r", expiresAt: now.addingTimeInterval(3599)))
        let refreshed = try GoogleOAuth.parseTokenResponse(data: Data(#"{"access_token":"ya29.y","expires_in":3599}"#.utf8),
                                                           status: 200, now: now, previousRefreshToken: "1//r")
        #expect(refreshed.refreshToken == "1//r")
        #expect(throws: GoogleOAuthError.tokenEndpoint(status: 400, message: "invalid_grant: Bad Request")) {
            try GoogleOAuth.parseTokenResponse(data: Data(#"{"error":"invalid_grant","error_description":"Bad Request"}"#.utf8),
                                               status: 400, now: now, previousRefreshToken: nil)
        }
        #expect(throws: GoogleOAuthError.malformedTokenResponse) {
            try GoogleOAuth.parseTokenResponse(data: Data(#"{"token_type":"Bearer"}"#.utf8), status: 200, now: now, previousRefreshToken: nil)
        }
    }
}

final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    init(_ data: Data?) { self.data = data }
    func load() -> Data? { lock.withLock { data } }
    func save(_ d: Data) { lock.withLock { data = d } }
}

@Suite struct GoogleAccessTokenProviderTests {
    let now = Date(timeIntervalSince1970: 2_000_000)

    @Test func freshTokenIsReturnedWithoutNetwork() async throws {
        let box = TokenBox(try JSONEncoder().encode(GoogleToken(accessToken: "a1", refreshToken: "r", expiresAt: now.addingTimeInterval(600))))
        let transport = QueueHTTPTransport([])
        let provider = GoogleAccessTokenProvider(clientId: "cid", transport: transport, load: { box.load() }, save: { box.save($0) }, now: { [now] in now })
        #expect(try await provider.accessToken() == "a1")
        #expect(await transport.requests.isEmpty)
    }

    @Test func expiringTokenIsRefreshedAndStored() async throws {
        let box = TokenBox(try JSONEncoder().encode(GoogleToken(accessToken: "a1", refreshToken: "r", expiresAt: now.addingTimeInterval(30))))
        let transport = QueueHTTPTransport([(200, #"{"access_token":"a2","expires_in":3600}"#)])
        let provider = GoogleAccessTokenProvider(clientId: "cid", transport: transport, load: { box.load() }, save: { box.save($0) }, now: { [now] in now })
        #expect(try await provider.accessToken() == "a2")
        let stored = try JSONDecoder().decode(GoogleToken.self, from: try #require(box.load()))
        #expect(stored.refreshToken == "r")
        #expect(stored.expiresAt == now.addingTimeInterval(3600))
        #expect(await transport.requests.first?.url?.absoluteString == "https://oauth2.googleapis.com/token")
    }

    @Test func missingTokenMeansNotSignedIn() async throws {
        let provider = GoogleAccessTokenProvider(clientId: "cid", transport: QueueHTTPTransport([]), load: { nil }, save: { _ in }, now: { Date() })
        await #expect(throws: GoogleOAuthError.notSignedIn) { try await provider.accessToken() }
    }
}

@Suite struct GoogleSheetsTableSourceTests {
    @Test func requestsUnformattedValuesWithBearerToken() async throws {
        let transport = QueueHTTPTransport([(200, #"{"range":"Ceny!A1:D3","majorDimension":"ROWS","values":[["Country","Currency","Price","Trial"],["Czech Republic","CZK",249,7],["Korea, Republic of","KRW",14900.5,"ONE_MONTH"],["Germany","EUR",1234567.891,true]]}"#)])
        let source = GoogleSheetsTableSource(spreadsheetId: "sheet-123", range: "Ceny 2026!A1:D200", transport: transport, accessToken: { "tok" })
        let rows = try await source.fetchRows()
        #expect(rows == [["Country", "Currency", "Price", "Trial"], ["Czech Republic", "CZK", "249", "7"],
                         ["Korea, Republic of", "KRW", "14900.5", "ONE_MONTH"], ["Germany", "EUR", "1234567.891", "TRUE"]])
        let request = try #require(await transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(request.httpMethod == "GET")
        let url = try #require(request.url?.absoluteString)
        #expect(url == "https://sheets.googleapis.com/v4/spreadsheets/sheet-123/values/Ceny%202026!A1:D200?valueRenderOption=UNFORMATTED_VALUE&majorDimension=ROWS")
    }

    @Test func nonASCIISheetNamesArePercentEncoded() async throws {
        let transport = QueueHTTPTransport([(200, #"{"values":[["a"]]}"#)])
        _ = try await GoogleSheetsTableSource(spreadsheetId: "s", range: "'Ceník 2026'!A1:B2", transport: transport, accessToken: { "t" }).fetchRows()
        let url = try #require(await transport.requests.first?.url?.absoluteString)
        #expect(url.hasPrefix("https://sheets.googleapis.com/v4/spreadsheets/s/values/%27Cen%C3%ADk%202026%27!A1:B2?"))
    }

    @Test func emptyRangeHasNoValues() async throws {
        let source = GoogleSheetsTableSource(spreadsheetId: "s", range: "A1:B2", transport: QueueHTTPTransport([(200, #"{"range":"A1:B2"}"#)]), accessToken: { "t" })
        #expect(try await source.fetchRows().isEmpty)
    }

    @Test func httpErrorsAreMapped() async throws {
        let unauthorized = GoogleSheetsTableSource(spreadsheetId: "s", range: "A1", transport: QueueHTTPTransport([(401, "{}")]), accessToken: { "t" })
        await #expect(throws: GoogleSheetsError.unauthorized) { try await unauthorized.fetchRows() }
        let forbidden = GoogleSheetsTableSource(spreadsheetId: "s", range: "A1", transport: QueueHTTPTransport([(403, "denied")]), accessToken: { "t" })
        await #expect(throws: GoogleSheetsError.http(status: 403, message: "denied")) { try await forbidden.fetchRows() }
    }
}
