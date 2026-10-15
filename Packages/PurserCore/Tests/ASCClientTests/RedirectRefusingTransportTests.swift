import Foundation
import Testing
@testable import ASCClient
import PurserTestSupport

@Suite struct RedirectRefusingTransportTests {
    private func put(_ url: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "PUT"
        request.httpBody = Data([1, 2])
        return request
    }

    @Test func theSessionKeepsNothingBetweenRequests() {
        let configuration = RedirectRefusingTransport().configuration
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(!configuration.httpShouldSetCookies)
    }

    @Test func aRedirectComesBackAsTheResponseAndIsNeverFollowed() async throws {
        let token = UUID().uuidString
        let transport = RedirectRefusingTransport(protocolClasses: [StubRedirectProtocol.self])
        let (_, response) = try await transport.send(put("https://upload.fake.apple.com/redirect/\(token)"))
        #expect(response.statusCode == 307)
        #expect(response.url?.host == "upload.fake.apple.com")
        #expect(StubRedirectProtocol.loaded(containing: token) == ["https://upload.fake.apple.com/redirect/\(token)"])
    }

    @Test func anAnswerWithoutARedirectPassesThrough() async throws {
        let token = UUID().uuidString
        let transport = RedirectRefusingTransport(protocolClasses: [StubRedirectProtocol.self])
        let (data, response) = try await transport.send(put("https://upload.fake.apple.com/ok/\(token)"))
        #expect(response.statusCode == 200 && data == Data([1, 2, 3]))
    }
}
