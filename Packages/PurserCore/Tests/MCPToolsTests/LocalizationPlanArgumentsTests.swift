import Foundation
import Testing
import Domain
import Catalog
import Policy
import Planner
import Store
import MCPBridge
@testable import MCPTools
import PurserTestSupport

private func d(_ text: String) -> Decimal { Decimal(string: text)! }
private let s = LocalizationOwner.subscription("s")
private let group = LocalizationOwner.group("group-1")

private func catalog() -> SyntheticCatalog {
    var catalog = SyntheticCatalog()
    catalog.addSubscription("s", prices: ["USA": d("29.99")])
    catalog.addIAP("life", base: "USA", manual: ["USA": d("49.99")])
    catalog.addGroup()
    catalog.addTexts(s, live: [:], pending: ["en-US": LocalizationText(name: "Fruit Yearly", description: "All fruit")], pendingState: .prepareForSubmission)
    catalog.addTexts(group, live: [:], pending: ["en-US": LocalizationText(name: "Fruit Premium", customAppName: "Fruit")],
                     pendingState: .prepareForSubmission)
    catalog.addTexts(.iap("life"), live: [:], pending: ["en-US": LocalizationText(name: "Fruit Lifetime")], pendingState: .prepareForSubmission)
    return catalog
}

private func snapshot() -> CatalogSnapshot { catalog().snapshot() }

private func message(_ body: () throws -> Void) -> String? {
    do { try body() } catch let error as ToolArgumentError { return error.message } catch { return "other: \(error)" }
    return nil
}

/// The edits planned against the synthetic catalog and rendered the way get_plan renders them.
private func renderedPlan(_ spec: LocalizationPlanSpec) throws -> JSONValue {
    let catalog = snapshot()
    let config = SyntheticCatalog.config()
    let spec = PlanSpec.localization(spec)
    let draft = try Planner(policy: PolicyEngine()).plan(spec, context: PlanningContext(snapshot: catalog, config: config, today: SyntheticCatalog.today))
    let rows = PlanDiff.rows(items: draft.items, verdicts: draft.verdicts, spec: spec, snapshot: catalog, config: config, today: SyntheticCatalog.today)
    let stored = StoredPlan(id: "p1", origin: .localization, specJSON: "{}", importJSON: nil, binding: PlanBinding(config: config),
                            baseSyncId: draft.baseSyncId, state: .draft, pauseReason: nil, endReason: nil, planHash: draft.planHash,
                            verdictHash: draft.verdictHash, verdicts: draft.verdicts, excluded: draft.excluded, productStates: [:],
                            reason: nil, confirmationLevel: draft.confirmationLevel, appBuild: "test", estimateRequests: draft.estimate.requests,
                            estimateMinutes: draft.estimate.minutes, replanOf: nil, createdAt: Date(timeIntervalSince1970: 0),
                            updatedAt: Date(timeIntervalSince1970: 0), heartbeatAt: nil)
    let items = draft.items.map { StoredItem(planId: "p1", item: $0, state: .pending, attempts: 0, ascId: nil, errorJSON: nil,
                                             verifiedAt: nil, effectiveAt: nil, supersededBy: nil) }
    return MCPRender.plan(stored, items: items, rows: rows, appName: config.name, productName: { $0 }, flaggedOnly: false, maxRows: 10)
}

@Suite struct LocalizationPlanArgumentsTests {
    @Test func rowsResolveProductsAndGroupsAndEmptyCellsKeepTheText() throws {
        let arguments: JSONValue = ["rows": [
            ["product": "com.example.s", "locale": "en-US", "description": "Fresh fruit"],
            ["product": "group:Synthetic group", "locale": "en-US", "custom_app_name": "Fruit+"],
            ["product": "life", "locale": "cs", "name": "Doživotně", "description": ""],
        ], "reason": " translations "]
        let parsed = LocalizationPlanArguments(arguments, snapshot: snapshot())
        #expect(parsed.reason == "translations")
        guard case let .localization(spec) = try parsed.spec() else { Issue.record("not a localization spec"); return }
        #expect(spec.edits == [
            LocalizationEdit(owner: s, locale: "en-US", description: "Fresh fruit"),
            LocalizationEdit(owner: group, locale: "en-US", customAppName: "Fruit+"),
            LocalizationEdit(owner: .iap("life"), locale: "cs", name: "Doživotně"),
        ])
    }

    @Test func aRowPurserCannotPlaceRefusesTheWholeCall() {
        let catalog = snapshot()
        #expect(message { _ = try LocalizationPlanArguments(["rows": []], snapshot: catalog).spec() }?.contains("“rows” is required") == true)
        #expect(message { _ = try LocalizationPlanArguments(["rows": [["product": "com.example.s"]]], snapshot: catalog).spec() }
                == "Row 1 needs “locale”.")
        #expect(message { _ = try LocalizationPlanArguments(["rows": [["product": "com.example.s", "locale": "cs", "name": 7]]], snapshot: catalog).spec() }
                == "Row 1: “name” must be a string.")
        let refused = message {
            _ = try LocalizationPlanArguments(["rows": [["product": "com.example.s", "locale": "cs", "name": "Ovoce"],
                                                        ["product": "com.example.nope", "locale": "cs", "name": "X"]]], snapshot: catalog).spec()
        }
        #expect(refused?.hasPrefix("Nothing was planned.") == true)
        #expect(refused?.contains("Row 2:") == true)
        #expect(refused?.hasSuffix(" get_localizations shows every product and group with the name to use.") == true)
        // A row whose owner is known but whose fields do not fit it needs no pointer to get_localizations.
        let misplaced = message {
            _ = try LocalizationPlanArguments(["rows": [["product": "com.example.s", "locale": "cs", "custom_app_name": "Ovoce"]]],
                                              snapshot: catalog).spec()
        }
        #expect(misplaced == "Nothing was planned. Row 1: only a subscription group has a custom app name.")
    }

    @Test func aRowWithAFieldTheToolDoesNotKnowIsRefused() {
        let catalog = snapshot()
        let misspelt = message {
            _ = try LocalizationPlanArguments(["rows": [["product": "com.example.s", "locale": "cs", "name": "Ovoce"],
                                                        ["product": "group:Synthetic group", "locale": "cs", "customAppName": "Ovoce"]]],
                                              snapshot: catalog).spec()
        }
        #expect(misspelt == "Row 2: unknown field “customAppName”; use product, locale, name, description, custom_app_name.")
    }

    @Test func planRowsOfTextsCarryTheLocaleAndBothTexts() throws {
        let rendered = try renderedPlan(LocalizationPlanSpec(edits: [LocalizationEdit(owner: s, locale: "en-US", description: "Fresh fruit")]))
        #expect(rendered["origin"] == "L10N")
        let row = try #require(rendered["rows"]?.arrayValue?.first)
        #expect(row["op"] == "SET_TEXT")
        #expect(row["locale"] == "en-US")
        #expect(row["territory"] == .null)
        #expect(row["before_text"]?["description"] == "All fruit")
        #expect(row["after_text"]?["description"] == "Fresh fruit")
        #expect(row["after_text"]?["custom_app_name"] == .null)
        #expect(row["changed_fields"] == ["description"])
        #expect(MCPRender.localizationText(nil) == .null)
    }

    @Test func aGroupsChangedFieldIsNamedLikeTheToolArgument() throws {
        let rendered = try renderedPlan(LocalizationPlanSpec(edits: [LocalizationEdit(owner: group, locale: "en-US", customAppName: "Fruit+")]))
        let row = try #require(rendered["rows"]?.arrayValue?.first)
        #expect(row["after_text"]?["custom_app_name"] == "Fruit+")
        #expect(row["changed_fields"] == ["custom_app_name"])
    }

    // Requested by the coordinator: get_localizations and create_localization_plan name owners the same way.

    @Test func twoGroupsWithTheSameNameRoundTripFromGetLocalizationsIntoCreateLocalizationPlan() throws {
        var twins = catalog()
        twins.addGroup("group-2", name: "Synthetic group")
        twins.addTexts(.group("group-2"), live: [:], pending: ["en-US": LocalizationText(name: "Fruit Basic", customAppName: "Basic")],
                       pendingState: .prepareForSubmission)
        let snapshot = twins.snapshot()
        let rendered = MCPRender.localizations(snapshot.owners(), snapshot: snapshot, locales: nil)
        let products: [String: String] = Dictionary(uniqueKeysWithValues: try #require(rendered["owners"]?.arrayValue).compactMap { entry in
            guard let id = entry["asc_id"]?.stringValue, let product = entry["product"]?.stringValue else { return nil }
            return (id, product)
        })
        #expect(products["group-1"] == "group:group-1")
        #expect(products["group-2"] == "group:group-2")

        let arguments: JSONValue = ["rows": [
            ["product": .string(try #require(products["group-1"])), "locale": "cs", "custom_app_name": "Ovoce"],
            ["product": .string(try #require(products["group-2"])), "locale": "cs", "custom_app_name": "Zaklad"],
            ["product": .string(try #require(products["s"])), "locale": "cs", "name": "Ročně"],
            ["product": .string(try #require(products["life"])), "locale": "cs", "name": "Doživotně"],
        ]]
        guard case let .localization(spec) = try LocalizationPlanArguments(arguments, snapshot: snapshot).spec() else {
            Issue.record("not a localization spec"); return
        }
        #expect(spec.edits.map(\.owner) == [.group("group-1"), .group("group-2"), s, .iap("life")])
    }

    @Test func aReferenceThatNamesMoreThanOneProductIsRefusedByBothTools() throws {
        var clash = catalog()
        clash.subscriptions["s"]?.productId = "life"   // the Product ID of a subscription is the ASC id of an in-app purchase
        let snapshot = clash.snapshot()
        let planned = message { _ = try LocalizationPlanArguments(["rows": [["product": "life", "locale": "cs", "name": "X"]]], snapshot: snapshot).spec() }
        #expect(planned?.hasPrefix("Nothing was planned. Row 1: more than one product is named “life”") == true)
        let read = message { _ = try LocalizationArguments(["products": ["life"]], snapshot: snapshot).owners() }
        #expect(read?.hasPrefix("More than one product is named “life”") == true)

        // The renderer names each of them so that the other tool takes it back.
        let rendered = MCPRender.localizations([s, .iap("life")], snapshot: snapshot, locales: nil)
        let products = try #require(rendered["owners"]?.arrayValue).compactMap { $0["product"]?.stringValue }
        #expect(products == ["s", "com.example.life"])
        let rows: JSONValue = .array(products.map { ["product": .string($0), "locale": "cs", "name": "X"] })
        guard case let .localization(spec) = try LocalizationPlanArguments(["rows": rows], snapshot: snapshot).spec() else {
            Issue.record("not a localization spec"); return
        }
        #expect(spec.edits.map(\.owner) == [s, .iap("life")])
    }

    @Test func theGroupPrefixIsReadWhateverItsCaseByBothToolsAndRefusedAlikeWhenTheNameIsShared() throws {
        let snapshot = snapshot()
        let rows: JSONValue = ["rows": [["product": "Group:Synthetic group", "locale": "cs", "custom_app_name": "Ovoce"],
                                        ["product": "GROUP:group-1", "locale": "de-DE", "custom_app_name": "Obst"]]]
        guard case let .localization(spec) = try LocalizationPlanArguments(rows, snapshot: snapshot).spec() else {
            Issue.record("not a localization spec"); return
        }
        #expect(spec.edits.map(\.owner) == [group, group])
        #expect(try LocalizationArguments(["products": ["Group:Synthetic group", "GROUP:group-1"]], snapshot: snapshot).owners() == [group])

        var twins = catalog()
        twins.addGroup("group-2", name: "Synthetic group")
        let shared = twins.snapshot()
        let planned = message { _ = try LocalizationPlanArguments(["rows": [["product": "Group:Synthetic group", "locale": "cs", "name": "X"]]], snapshot: shared).spec() }
        #expect(planned?.contains("group:<ASC id>") == true)
        #expect(planned?.contains("get_localizations shows every product and group with the name to use.") == true)
        let read = message { _ = try LocalizationArguments(["products": ["Group:Synthetic group"]], snapshot: shared).owners() }
        #expect(read?.contains("group:<ASC id>") == true)
    }
}
