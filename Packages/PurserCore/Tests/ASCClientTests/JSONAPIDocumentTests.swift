import Foundation
import Testing
import ASCClient

@Suite struct JSONAPIDocumentTests {
    private func decode(_ text: String) throws -> JSONAPIDocument {
        try JSONDecoder().decode(JSONAPIDocument.self, from: Data(text.utf8))
    }

    @Test func singleResourceWithIncludedLinkage() throws {
        let document = try decode("""
        {"data":{"type":"subscriptionPrices","id":"price-1",
                 "attributes":{"startDate":"2026-11-01","preserved":false,"planType":null,"count":3},
                 "relationships":{"territory":{"data":{"type":"territories","id":"USA"}},
                                  "subscriptionPricePoint":{"links":{"related":"https://example.invalid"}}}},
         "included":[{"type":"territories","id":"USA","attributes":{"currency":"USD"}}]}
        """)
        #expect(!document.isCollection)
        let resource = try #require(document.data.first)
        #expect(resource.string("startDate") == "2026-11-01")
        #expect(resource.bool("preserved") == false)
        #expect(resource.string("planType") == nil)
        #expect(resource.attributes["planType"] == .null)
        #expect(resource.int("count") == 3)
        #expect(resource.relatedID("territory") == "USA")
        #expect(resource.relationships["subscriptionPricePoint"]?.data == nil)
        #expect(resource.relatedID("subscriptionPricePoint") == nil)
        #expect(document.includedResource(type: "territories", id: "USA")?.string("currency") == "USD")
    }

    @Test func collectionWithPagingAndNullData() throws {
        let page = try decode(#"{"data":[],"links":{"self":"x","next":"https://api.appstoreconnect.apple.com/v1/territories?cursor=AB"},"meta":{"paging":{"total":175,"limit":200}}}"#)
        #expect(page.isCollection)
        #expect(page.data.isEmpty)
        #expect(page.total == 175)
        #expect(page.nextURL?.query == "cursor=AB")
        let empty = try decode(#"{"data":null}"#)
        #expect(empty.data.isEmpty)
        #expect(!empty.isCollection)
    }

    @Test func toManyRelationshipLinkage() throws {
        let document = try decode(#"{"data":[{"type":"subscriptionAvailabilities","id":"av-1","relationships":{"availableTerritories":{"data":[{"type":"territories","id":"USA"},{"type":"territories","id":"CZE"}]}}}]}"#)
        #expect(document.data.first?.relationships["availableTerritories"]?.data?.map(\.id) == ["USA", "CZE"])
    }

    @Test func numbersDecodeAsDecimalAndAccessorsAreTyped() throws {
        let document = try decode(#"{"data":{"type":"x","id":"1","attributes":{"price":29.99,"big":12345678901,"half":2.5,"whole":3.0,"flag":true,"name":"Fruit","list":[1,"a"],"nested":{"k":null}}}}"#)
        let resource = try #require(document.data.first)
        #expect(resource.attributes["price"] == .number(Decimal(string: "29.99")!))
        #expect(resource.int("big") == 12_345_678_901)
        #expect(resource.int("half") == nil)
        #expect(resource.int("whole") == 3)
        #expect(resource.attributes["price"]?.stringValue == nil)
        #expect(resource.attributes["name"]?.stringValue == "Fruit")
        #expect(resource.attributes["flag"]?.boolValue == true)
        #expect(resource.attributes["flag"]?.intValue == nil)
        #expect(resource.attributes["list"] == .array([.number(1), .string("a")]))
        #expect(resource.attributes["nested"] == .object(["k": .null]))
        #expect(resource.bool("name") == nil)
        #expect(resource.string("flag") == nil)
    }
}
