import Foundation
import Testing
import ASCClient
import Audit
import Domain
import Executor
import Store
import PurserTestSupport

/// Answers 200 from another URL than the request's: a transport that followed a redirect.
private struct RedirectingTransport: HTTPTransport {
    let finalURL: URL
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (Data([1, 2, 3]), HTTPURLResponse(url: finalURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

/// A response that does not say where it came from.
private final class NoURLResponse: HTTPURLResponse, @unchecked Sendable {
    override var url: URL? { nil }
}

private struct AnonymousTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (Data([1, 2, 3]), NoURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

/// Fails like URLSession: the error carries the failing URL, pre-signed query included.
private struct FailingTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: request.url!, NSURLErrorFailingURLStringErrorKey: request.url!.absoluteString,
                                             NSLocalizedDescriptionKey: "timed out: \(request.url!.absoluteString)"])
    }
}

@Suite struct AssetTransferTests {
    private func audit() throws -> AuditLog {
        AuditLog(database: try WorkspaceDatabase.inMemory(), actor: { "001234.synthetic-owner.0001" }, now: { Sample.fixedNow })
    }

    private func screenshot(_ template: String?) -> ReviewScreenshot {
        ReviewScreenshot(ascId: "shot-1", fileName: "a.png", fileSize: 70, templateURL: template, width: 1242, height: 2688, deliveryState: "COMPLETE")
    }

    private func operation(_ url: String, offset: Int, length: Int, method: String = "PUT",
                           headers: [String: String] = ["Content-Type": "image/png"]) -> UploadOperation {
        UploadOperation(method: method, url: URL(string: url)!, offset: offset, length: length, headers: headers)
    }

    private func payload(_ event: AuditEvent) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(event.payloadJSON.utf8)) as? [String: Any])
    }

    /// The upload is refused as unusable, nothing is sent and nothing is audited.
    private func expectBadOperation(_ operations: [UploadOperation], size: Int = 10, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let transport = QueueHTTPTransport([(200, ""), (200, "")])
        let log = try audit()
        do {
            try await AssetTransfer(transport: transport, audit: log).upload(Data(count: size), operations: operations, refs: [:])
            Issue.record("the upload was accepted", sourceLocation: sourceLocation)
        } catch let error as AssetTransferError {
            guard case .badOperation = error else {
                Issue.record("expected badOperation, got \(error)", sourceLocation: sourceLocation)
                return
            }
        }
        #expect(await transport.requests.isEmpty, sourceLocation: sourceLocation)
        #expect(try log.events(after: 0, limit: 10).isEmpty, sourceLocation: sourceLocation)
    }

    // MARK: Hosts

    @Test func onlyHTTPSToAppleHostsIsAllowed() {
        for allowed in ["https://is1-ssl.mzstatic.com/image/thumb/a.png", "https://store-032.blobstore.apple.com/upload?x=1",
                        "https://upload.fake.apple.com/screenshot/1/part-1"] {
            #expect(AssetTransfer.isAllowed(URL(string: allowed)!), "\(allowed)")
        }
        for refused in ["http://is1-ssl.mzstatic.com/a.png", "https://example.com/a.png", "https://apple.com.example.net/a",
                        "https://notapple.com/a", "https://mzstatic.com.example.net/a", "https://user@upload.fake.apple.com/a",
                        "ftp://upload.fake.apple.com/a"] {
            #expect(!AssetTransfer.isAllowed(URL(string: refused)!), "\(refused)")
        }
    }

    /// URL.host decodes percent escapes: "evil.com%2F.apple.com" has the host "evil.com/.apple.com", which ends in ".apple.com".
    @Test func aHostWithEncodedSeparatorsIsRefused() throws {
        for refused in ["https://evil.com%2F.apple.com/a", "https://evil.com%00.apple.com/a", "https://evil.com%5C.mzstatic.com/a",
                        "https://upload.apple%2Ecom/a", "https://upload.apple.com./a"] {
            let url = try #require(URL(string: refused), "\(refused)")
            #expect(!AssetTransfer.isAllowed(url), "\(refused)")
        }
    }

    @Test func theImageURLFillsTheTemplateWithTheSizeAndPNG() {
        #expect(AssetTransfer.imageURL(screenshot("https://is1-ssl.mzstatic.com/image/thumb/x/{w}x{h}bb.{f}"))?.absoluteString
                == "https://is1-ssl.mzstatic.com/image/thumb/x/1242x2688bb.png")
        var noSize = screenshot("https://is1-ssl.mzstatic.com/{w}x{h}.{f}")
        noSize.width = nil
        #expect(AssetTransfer.imageURL(noSize) == nil)
        #expect(AssetTransfer.imageURL(screenshot(nil)) == nil)
    }

    @Test func theChecksumIsTheMD5OfTheFile() {
        #expect(AssetTransfer.md5(Data()) == "d41d8cd98f00b204e9800998ecf8427e")
        #expect(AssetTransfer.md5(Data("abc".utf8)) == "900150983cd24fb0d6963f7d28e17f72")
    }

    @Test func uploadOperationsAreReadFromAReservation() throws {
        let document = try JSONDecoder().decode(JSONAPIDocument.self, from: Data("""
        {"data":{"type":"subscriptionAppStoreReviewScreenshots","id":"shot-1","attributes":{"uploadOperations":[
          {"method":"PUT","url":"https://upload.fake.apple.com/a?token=t","offset":0,"length":40,"requestHeaders":[{"name":"Content-Type","value":"image/png"}]},
          {"method":"PUT","url":"https://upload.fake.apple.com/b?token=t","offset":40,"length":30,"requestHeaders":[]}]}}}
        """.utf8))
        let resource = try #require(document.data.first)
        let operations = try #require(UploadOperation.list(from: resource))
        #expect(operations == [
            UploadOperation(method: "PUT", url: URL(string: "https://upload.fake.apple.com/a?token=t")!, offset: 0, length: 40,
                            headers: ["Content-Type": "image/png"]),
            UploadOperation(method: "PUT", url: URL(string: "https://upload.fake.apple.com/b?token=t")!, offset: 40, length: 30, headers: [:]),
        ])
        let broken = try JSONDecoder().decode(JSONAPIDocument.self, from: Data(
            #"{"data":{"type":"x","id":"shot-2","attributes":{"uploadOperations":[{"method":"PUT","offset":0,"length":1}]}}}"#.utf8))
        let brokenResource = try #require(broken.data.first)
        #expect(UploadOperation.list(from: brokenResource) == nil)
    }

    // MARK: Refusals before anything is sent

    @Test func refusedURLsSendNothingAndAuditNothing() async throws {
        let transport = QueueHTTPTransport([(200, "")])
        let log = try audit()
        let transfer = AssetTransfer(transport: transport, audit: log)
        await #expect(throws: AssetTransferError.refusedURL("https://example.com")) {
            _ = try await transfer.download(self.screenshot("https://example.com/{w}x{h}.{f}"))
        }
        await #expect(throws: AssetTransferError.refusedURL("http://upload.fake.apple.com")) {
            try await transfer.upload(Data(count: 10), operations: [self.operation("https://upload.fake.apple.com/p1", offset: 0, length: 5),
                                                                    self.operation("http://upload.fake.apple.com/p2?token=secret", offset: 5, length: 5)], refs: [:])
        }
        await #expect(throws: AssetTransferError.self) {
            try await transfer.upload(Data(count: 10), operations: [self.operation("https://upload.fake.apple.com/p1", offset: 6, length: 5)], refs: [:])
        }
        #expect(await transport.requests.isEmpty)
        #expect(try log.events(after: 0, limit: 10).isEmpty)
    }

    @Test func aPartThatIsNotAPUTIsRefused() async throws {
        try await expectBadOperation([operation("https://upload.fake.apple.com/p1", offset: 0, length: 10, method: "POST")])
        try await expectBadOperation([operation("https://upload.fake.apple.com/p1", offset: 0, length: 5),
                                      operation("https://upload.fake.apple.com/p2", offset: 5, length: 5, method: "DELETE")])
    }

    @Test func offsetsAndLengthsThatCouldOverflowAreRefusedWithoutACrash() async throws {
        for (offset, length) in [(Int.max, 1), (Int.max - 1, 5), (1, Int.max), (Int.max, Int.max), (Int.min, 5), (-1, 5), (0, 0), (0, -3), (0, 11), (10, 1)] {
            try await expectBadOperation([operation("https://upload.fake.apple.com/p1", offset: offset, length: length)])
        }
    }

    @Test func anEmptyListOfOperationsIsRefused() async throws {
        try await expectBadOperation([])
    }

    @Test func operationsThatDoNotCoverTheFileExactlyOnceAreRefused() async throws {
        let url = "https://upload.fake.apple.com/p"
        try await expectBadOperation([operation(url + "1", offset: 0, length: 4), operation(url + "2", offset: 5, length: 5)])    // gap
        try await expectBadOperation([operation(url + "1", offset: 0, length: 6), operation(url + "2", offset: 5, length: 5)])    // overlap
        try await expectBadOperation([operation(url + "1", offset: 0, length: 5)])                                                  // short
        try await expectBadOperation([operation(url + "1", offset: 0, length: 10), operation(url + "2", offset: 0, length: 10)])  // twice
        try await expectBadOperation([operation(url + "1", offset: 0, length: 5), operation(url + "2", offset: 5, length: 4)])    // one byte short
    }

    @Test func headersThatCouldInjectAnythingAreRefused() async throws {
        let url = "https://upload.fake.apple.com/p1"
        for headers in [["Content-Type": "image/png\r\nX-Injected: 1"], ["Content-Type": "image/png\nX-Injected: 1"], ["Content-Type": "image/png\0"],
                        ["Bad Name": "x"], ["Bad:Name": "x"], ["": "x"], ["X-Näme": "x"], ["X-Name\r\nX-Injected": "x"]] {
            try await expectBadOperation([operation(url, offset: 0, length: 10, headers: headers)])
        }
        // A bad part is found before the first good one is sent.
        try await expectBadOperation([operation(url, offset: 0, length: 5), operation(url, offset: 5, length: 5, headers: ["Content-Type": "a\r\nb"])])
    }

    // MARK: Redirects and responses

    @Test func aRedirectToAnotherHostIsRefused() async throws {
        let transfer = AssetTransfer(transport: RedirectingTransport(finalURL: URL(string: "https://example.com/a.png?token=secret")!), audit: try audit())
        await #expect(throws: AssetTransferError.refusedURL("https://example.com")) {
            _ = try await transfer.download(self.screenshot("https://is1-ssl.mzstatic.com/{w}x{h}.{f}"))
        }
    }

    @Test func aResponseWithoutAURLIsRefused() async throws {
        let log = try audit()
        let transfer = AssetTransfer(transport: AnonymousTransport(), audit: log)
        await #expect(throws: AssetTransferError.refusedURL("an unknown URL")) {
            _ = try await transfer.download(self.screenshot("https://is1-ssl.mzstatic.com/{w}x{h}.{f}"))
        }
        await #expect(throws: AssetTransferError.refusedURL("an unknown URL")) {
            try await transfer.upload(Data(count: 4), operations: [self.operation("https://upload.fake.apple.com/p1", offset: 0, length: 4)], refs: [:])
        }
        let events = try log.events(after: 0, limit: 10)
        #expect(events.map(\.type) == [.httpSent, .httpReceived])
        #expect(try payload(events[1])["status"] as? Int == 200)
    }

    @Test func aRedirectOfAPartToAnotherHostIsRefusedAndAuditedWithItsStatusAndWithoutTheURL() async throws {
        let log = try audit()
        let transfer = AssetTransfer(transport: RedirectingTransport(finalURL: URL(string: "https://example.com/a?token=secret-3")!), audit: log)
        await #expect(throws: AssetTransferError.refusedURL("https://example.com")) {
            try await transfer.upload(Data(count: 4), operations: [self.operation("https://upload.fake.apple.com/p1?token=secret-1", offset: 0, length: 4)],
                                      refs: [:])
        }
        let events = try log.events(after: 0, limit: 10)
        #expect(events.map(\.type) == [.httpSent, .httpReceived])
        #expect(!events.contains { $0.payloadJSON.contains("secret") })
        #expect(try payload(events[1])["status"] as? Int == 200)
        #expect((try payload(events[1])["error"] as? String)?.contains("refused https://example.com") == true)
    }

    @Test func theRedirectRefusingTransportStopsARedirectBeforeItIsFollowed() async throws {
        let token = UUID().uuidString
        let transport = RedirectRefusingTransport(protocolClasses: [StubRedirectProtocol.self])
        let log = try audit()
        let transfer = AssetTransfer(transport: transport, audit: log)
        await #expect(throws: AssetTransferError.http(status: 307, host: "upload.fake.apple.com")) {
            try await transfer.upload(Data(count: 4), operations: [self.operation("https://upload.fake.apple.com/redirect/\(token)", offset: 0, length: 4)],
                                      refs: [:])
        }
        await #expect(throws: AssetTransferError.http(status: 307, host: "is1-ssl.mzstatic.com")) {
            _ = try await transfer.download(self.screenshot("https://is1-ssl.mzstatic.com/redirect/\(token)/{w}x{h}.{f}"))
        }
        // Neither request reached the host the 307 named.
        #expect(StubRedirectProtocol.loaded(containing: token).count == 2)
        #expect(StubRedirectProtocol.loaded(containing: token).allSatisfy { !$0.contains("example.com") })
        let events = try log.events(after: 0, limit: 10)
        #expect(events.map(\.type) == [.httpSent, .httpReceived])
        #expect(try payload(events[1])["status"] as? Int == 307)
    }

    @Test func theRedirectRefusingTransportDeliversAnAnswerWithoutARedirect() async throws {
        let token = UUID().uuidString
        let log = try audit()
        let transfer = AssetTransfer(transport: RedirectRefusingTransport(protocolClasses: [StubRedirectProtocol.self]), audit: log)
        try await transfer.upload(Data(count: 4), operations: [operation("https://upload.fake.apple.com/ok/\(token)", offset: 0, length: 4)], refs: [:])
        let data = try await transfer.download(screenshot("https://is1-ssl.mzstatic.com/ok/\(token)/{w}x{h}.{f}"))
        #expect(data == Data([1, 2, 3]))
        #expect(try log.events(after: 0, limit: 10).map(\.type) == [.httpSent, .httpReceived])
    }

    @Test func aDownloadThatIsNotAnAnswerOf2xxOrIsEmptyIsAnError() async throws {
        let template = "https://is1-ssl.mzstatic.com/{w}x{h}.{f}"
        await #expect(throws: AssetTransferError.http(status: 404, host: "is1-ssl.mzstatic.com")) {
            _ = try await AssetTransfer(transport: QueueHTTPTransport([(404, "gone")]), audit: try self.audit()).download(self.screenshot(template))
        }
        await #expect(throws: AssetTransferError.http(status: 500, host: "is1-ssl.mzstatic.com")) {
            _ = try await AssetTransfer(transport: QueueHTTPTransport([(500, "")]), audit: try self.audit()).download(self.screenshot(template))
        }
        await #expect(throws: AssetTransferError.noImage) {
            _ = try await AssetTransfer(transport: QueueHTTPTransport([(200, "")]), audit: try self.audit()).download(self.screenshot(template))
        }
    }

    @Test func aTransportErrorIsRecordedAsItsDomainAndCodeOnly() async throws {
        let log = try audit()
        let transfer = AssetTransfer(transport: FailingTransport(), audit: log)
        await #expect(throws: AssetTransferError.network("NSURLErrorDomain -1001")) {
            try await transfer.upload(Data(count: 4), operations: [self.operation("https://upload.fake.apple.com/p1?token=secret-9", offset: 0, length: 4)],
                                      refs: [:])
        }
        await #expect(throws: AssetTransferError.network("NSURLErrorDomain -1001")) {
            _ = try await transfer.download(self.screenshot("https://is1-ssl.mzstatic.com/{w}x{h}.{f}"))
        }
        let events = try log.events(after: 0, limit: 10)
        #expect(events.map(\.type) == [.httpSent, .httpReceived])
        #expect(try payload(events[1])["error"] as? String == "network: NSURLErrorDomain -1001")
        #expect(try payload(events[1])["status"] is NSNull)
        #expect(!events.contains { $0.payloadJSON.contains("secret") || $0.payloadJSON.contains("?") })
    }

    // MARK: Parts

    @Test func eachPartIsSentWithoutAuthorizationAndAuditedWithoutTheURL() async throws {
        let transport = QueueHTTPTransport([(200, ""), (200, "")])
        let log = try audit()
        let data = Data((0..<10).map(UInt8.init))
        try await AssetTransfer(transport: transport, audit: log).upload(data, operations: [
            operation("https://upload.fake.apple.com/screenshot/s1/part-1?token=secret-1", offset: 0, length: 6,
                      headers: ["Content-Type": "image/png", "Authorization": "Synthetic"]),
            operation("https://upload.fake.apple.com/screenshot/s1/part-2?token=secret-2", offset: 6, length: 4),
        ], refs: ["clone": "reviewScreenshot", "product": "SpikeYearlyA_AB3"])
        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["PUT", "PUT"])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil && !$0.httpShouldHandleCookies })
        #expect(requests[0].value(forHTTPHeaderField: "Content-Type") == "image/png")
        #expect(requests.map(\.httpBody) == [data.subdata(in: 0..<6), data.subdata(in: 6..<10)])
        let events = try log.events(after: 0, limit: 10)
        #expect(events.map(\.type) == [.httpSent, .httpReceived, .httpSent, .httpReceived])
        #expect(events.map { $0.refs["part"] } == ["1", "1", "2", "2"])
        #expect(events.allSatisfy { $0.refs["product"] == "SpikeYearlyA_AB3" && !$0.payloadJSON.contains("secret") })
        let sent = try payload(events[2])
        #expect(sent["method"] as? String == "PUT")
        #expect(sent["scheme"] as? String == "https")
        #expect(sent["host"] as? String == "upload.fake.apple.com")
        #expect(sent["part"] as? Int == 2)
        #expect(sent["offset"] as? Int == 6 && sent["length"] as? Int == 4)
        #expect(sent["path"] == nil && sent["url"] == nil)
        #expect(try payload(events[3])["status"] as? Int == 200)
    }

    @Test func noAuditEventHoldsThePathOfAnUploadURLOrTheBytes() async throws {
        let ok = QueueHTTPTransport([(200, ""), (500, "")])
        let log = try audit()
        let data = Data("synthetic-image-bytes".utf8)
        await #expect(throws: AssetTransferError.http(status: 500, host: "upload.fake.apple.com")) {
            try await AssetTransfer(transport: ok, audit: log).upload(data, operations: [
                self.operation("https://upload.fake.apple.com/screenshot/pathsecret-1/part-1?token=secret-1", offset: 0, length: 9),
                self.operation("https://upload.fake.apple.com/screenshot/pathsecret-2/part-2?token=secret-2", offset: 9, length: data.count - 9),
            ], refs: ["clone": "reviewScreenshot"])
        }
        let events = try log.events(after: 0, limit: 10)
        #expect(events.count == 4)
        for event in events {
            let text = event.payloadJSON + String(describing: event.refs)
            #expect(!text.contains("pathsecret") && !text.contains("/screenshot") && !text.contains("secret-") && !text.contains("synthetic-image"), "\(text)")
        }
    }

    @Test func credentialsCookiesAndFramingHeadersOfAReservationAreNeverSent() async throws {
        let transport = QueueHTTPTransport([(200, "")])
        let withheld = ["authorization": "Synthetic", "Cookie": "session=synthetic", "Proxy-Authorization": "Synthetic", "Proxy-Anything": "x",
                        "HOST": "example.com", "Connection": "keep-alive", "Transfer-Encoding": "chunked", "TE": "trailers", "Upgrade": "websocket"]
        try await AssetTransfer(transport: transport, audit: try audit()).upload(Data(count: 4), operations: [
            operation("https://upload.fake.apple.com/p1", offset: 0, length: 4,
                      headers: withheld.merging(["Content-Type": "image/png", "X-Apple-Part": "1"]) { current, _ in current }),
        ], refs: [:])
        let request = try #require(await transport.requests.first)
        #expect(Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }) == ["content-type", "x-apple-part"])
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "image/png")
        #expect(!request.httpShouldHandleCookies)
    }

    @Test func partsThatTileTheFileInAnyOrderAreSentInTheListedOrder() async throws {
        let transport = QueueHTTPTransport([(200, ""), (200, "")])
        let log = try audit()
        let data = Data((0..<10).map(UInt8.init))
        try await AssetTransfer(transport: transport, audit: log).upload(data, operations: [
            operation("https://upload.fake.apple.com/p2", offset: 5, length: 5), operation("https://upload.fake.apple.com/p1", offset: 0, length: 5),
        ], refs: [:])
        #expect(await transport.requests.map(\.httpBody) == [data.subdata(in: 5..<10), data.subdata(in: 0..<5)])
        #expect(try log.events(after: 0, limit: 10).map { $0.refs["part"] } == ["1", "1", "2", "2"])
    }

    @Test func aFailedPartIsAuditedWithItsStatusAndStopsTheUpload() async throws {
        let transport = QueueHTTPTransport([(200, ""), (500, "")])
        let log = try audit()
        await #expect(throws: AssetTransferError.http(status: 500, host: "upload.fake.apple.com")) {
            try await AssetTransfer(transport: transport, audit: log).upload(Data(count: 9), operations: [
                self.operation("https://upload.fake.apple.com/p1", offset: 0, length: 3),
                self.operation("https://upload.fake.apple.com/p2", offset: 3, length: 3),
                self.operation("https://upload.fake.apple.com/p3", offset: 6, length: 3),
            ], refs: [:])
        }
        #expect(await transport.requests.count == 2)
        let events = try log.events(after: 0, limit: 10)
        #expect(events.map(\.type) == [.httpSent, .httpReceived, .httpSent, .httpReceived])
        #expect(try payload(events[3])["status"] as? Int == 500)
    }

    @Test func theImageComesFromTheFakeCDNWithoutAToken() async throws {
        let fake = FakeASC(model: FakeSeed.cloneSource(), now: { Sample.fixedNow })
        let shot = ReviewScreenshot(ascId: "shot-spike-a", fileName: "a.png", fileSize: 70,
                                    templateURL: FakeASC.imageTemplate(screenshotId: "shot-spike-a"), width: 1, height: 1, deliveryState: "COMPLETE")
        let data = try await AssetTransfer(transport: fake, audit: try audit()).download(shot)
        #expect(data == FakeASC.samplePNG)
        let records = await fake.assetRequests()
        #expect(records.map(\.method) == ["GET"] && !records[0].hadAuthorization)
    }
}
