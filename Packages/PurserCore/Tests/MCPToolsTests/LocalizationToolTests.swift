import Foundation
import Testing
import Domain
import Catalog
import MCPBridge
@testable import MCPTools
import PurserTestSupport

@Suite struct LocalizationToolTests {
    private func catalog() -> SyntheticCatalog {
        var catalog = SyntheticCatalog()
        catalog.addSubscription("s", prices: ["USA": SyntheticCatalog.d("29.99")])
        catalog.addIAP("life", base: "USA", manual: ["USA": SyntheticCatalog.d("49.99")])
        catalog.addGroup()
        catalog.addTexts(.subscription("s"), live: ["en-US": LocalizationText(name: "Yearly", description: "Every fruit"),
                                                    "cs": LocalizationText(name: "Ročně", description: "Ovoce")],
                         pending: ["en-US": LocalizationText(name: "Yearly Plus", description: "Every fruit"),
                                   "cs": LocalizationText(name: "Ročně", description: "Ovoce")],
                         pendingState: .waitingForReview)
        catalog.addTexts(.group("group-1"), live: ["en-US": LocalizationText(name: "Premium", customAppName: "Fruit")])
        return catalog
    }

    private func parse(_ arguments: JSONValue, _ catalog: SyntheticCatalog? = nil) -> LocalizationArguments {
        LocalizationArguments(arguments, snapshot: (catalog ?? self.catalog()).snapshot())
    }

    @Test func productsAreNamedByProductIdAscIdOrGroupReferenceName() throws {
        let owners = try parse(["products": ["com.example.s", "life", "group:Synthetic group", "group:group-1", "s"]]).owners()
        #expect(owners == [.subscription("s"), .iap("life"), .group("group-1")])
        #expect(try parse(["products": []]).owners() == [.group("group-1"), .iap("life"), .subscription("s")])
        #expect(try parse([:]).owners() == [.group("group-1"), .iap("life"), .subscription("s")])
    }

    @Test func unknownOrAmbiguousNamesAreRefused() {
        #expect(throws: ToolArgumentError.self) { try parse(["products": ["nope"]]).owners() }
        #expect(throws: ToolArgumentError("No subscription group is named “Gone”. get_localizations shows every product and group with the name to use.")) {
            try parse(["products": ["group:Gone"]]).owners()
        }
        var twins = catalog()
        twins.addGroup("group-2", name: "Synthetic group")
        #expect(throws: ToolArgumentError("More than one subscription group is named “Synthetic group”; name it as group:<ASC id>. get_localizations shows every product and group with the name to use.")) {
            try parse(["products": ["group:Synthetic group"]], twins).owners()
        }
        #expect(throws: ToolArgumentError.self) { try parse(["products": [3]]).owners() }
        #expect(throws: ToolArgumentError.self) { try parse(["locales": [""]]).locales() }
    }

    @Test func theGroupPrefixIsReadWhateverItsCase() throws {
        #expect(try parse(["products": ["Group:Synthetic group", "GROUP:group-1", "group: Synthetic group "]]).owners() == [.group("group-1")])
    }

    @Test func aReferenceThatNamesMoreThanOneProductIsRefused() throws {
        var clash = catalog()
        clash.subscriptions["s"]?.productId = "life"   // the Product ID of a subscription is the ASC id of an in-app purchase
        #expect(throws: ToolArgumentError("More than one product is named “life”; name it by its ASC id. get_localizations shows every product and group with the name to use.")) {
            try parse(["products": ["life"]], clash).owners()
        }
        #expect(try parse(["products": ["s", "com.example.life"]], clash).owners() == [.subscription("s"), .iap("life")])
    }

    @Test func twoGroupsWithTheSameNameAreRenderedByAscIdAndReadBack() throws {
        var twins = catalog()
        twins.addGroup("group-2", name: "Synthetic group")
        twins.addTexts(.group("group-2"), live: ["en-US": LocalizationText(name: "Basic", customAppName: "Fruit")])
        let snapshot = twins.snapshot()
        let owners: [LocalizationOwner] = [.group("group-1"), .group("group-2"), .subscription("s"), .iap("life")]
        let rendered = MCPRender.localizations(owners, snapshot: snapshot, locales: nil)
        let products = try #require(rendered["owners"]?.arrayValue).compactMap { $0["product"]?.stringValue }
        #expect(products == ["group:group-1", "group:group-2", "com.example.s", "com.example.life"])
        #expect(try parse(["products": .array(products.map { .string($0) })], twins).owners() == owners)
    }

    @Test func aReferenceThatDoesNotLeadBackIsRenderedByAscId() throws {
        var clash = catalog()
        clash.subscriptions["s"]?.productId = "life"
        clash.addGroup("group-1", name: "group-2")   // named like the other group's ASC id
        clash.addGroup("group-2", name: "Other")
        let rendered = MCPRender.localizations([.subscription("s"), .iap("life"), .group("group-1")], snapshot: clash.snapshot(), locales: nil)
        let products = try #require(rendered["owners"]?.arrayValue).compactMap { $0["product"]?.stringValue }
        #expect(products == ["s", "com.example.life", "group:group-1"])
    }

    @Test func localesFilterIsOptional() throws {
        #expect(try parse([:]).locales() == nil)
        #expect(try parse(["locales": ["cs", " en-US "]]).locales() == ["cs", "en-US"])
    }

    @Test func rendersLiveAndPendingTextsWithTheirChange() throws {
        let snapshot = catalog().snapshot()
        let result = MCPRender.localizations([.subscription("s")], snapshot: snapshot, locales: nil)
        let owner = try #require(result["owners"]?.arrayValue?.first)
        #expect(owner["kind"] == "subscription")
        #expect(owner["product"] == "com.example.s")
        #expect(owner["name"] == "Synthetic s")
        #expect(owner["live_version"]?["number"] == 1)
        #expect(owner["pending_version"]?["state"] == "WAITING_FOR_REVIEW")
        let rows = try #require(owner["localizations"]?.arrayValue)
        #expect(rows.map { $0["locale"] } == ["cs", "en-US"])
        #expect(rows[0]["change"] == "none")
        #expect(rows[1]["live"] == ["name": "Yearly", "description": "Every fruit"])
        #expect(rows[1]["pending"] == ["name": "Yearly Plus", "description": "Every fruit"])
        #expect(rows[1]["change"] == "changed")

        let onlyCzech = MCPRender.localizations([.subscription("s")], snapshot: snapshot, locales: ["cs"])
        #expect(onlyCzech["owners"]?.arrayValue?.first?["localizations"]?.arrayValue?.count == 1)
    }

    @Test func aGroupShowsItsCustomAppNameAndAnOwnerWithoutVersionsIsEmpty() throws {
        let snapshot = catalog().snapshot()
        let result = MCPRender.localizations([.group("group-1"), .iap("life")], snapshot: snapshot, locales: nil)
        let owners = try #require(result["owners"]?.arrayValue)
        #expect(owners[0]["kind"] == "subscription_group")
        #expect(owners[0]["product"] == "group:Synthetic group")
        #expect(owners[0]["pending_version"] == .null)
        let row = try #require(owners[0]["localizations"]?.arrayValue?.first)
        #expect(row["live"] == ["name": "Premium", "custom_app_name": "Fruit"])
        #expect(row["pending"] == nil)
        #expect(row["change"] == nil)
        #expect(owners[1]["kind"] == "in_app_purchase")
        #expect(owners[1]["live_version"] == .null)
        #expect(owners[1]["localizations"] == [])
    }

    @Test func theToolIsReadOnly() throws {
        let definition = try #require(ToolCatalog.definition(named: "get_localizations"))
        #expect(definition.access == .read)
        #expect(definition.inputSchema["required"] == [])
    }
}
