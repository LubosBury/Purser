import Foundation
import Testing
import Domain
import Catalog
import Importer
import Policy
@testable import Planner
import PurserTestSupport

private let s = LocalizationOwner.subscription("s")
private let life = LocalizationOwner.iap("life")
private let group = LocalizationOwner.group("group-1")

/// s: live v1 (en-US) and draft v2 (en-US, cs); life: live v1 only (en-US); group-1: draft v1 (en-US).
private func catalog() -> SyntheticCatalog {
    var catalog = yearly()
    catalog.addIAP("life", base: "USA", manual: ["USA": d("49.99")])
    catalog.addGroup()
    catalog.addTexts(s, live: ["en-US": LocalizationText(name: "Fruit Yearly", description: "Old")], pending: [
        "en-US": LocalizationText(name: "Fruit Yearly", description: "All fruit, every day"),
        "cs": LocalizationText(name: "Ovoce ročně", description: "Všechno ovoce"),
    ], pendingState: .prepareForSubmission)
    catalog.addTexts(life, live: ["en-US": LocalizationText(name: "Fruit Lifetime", description: "Forever")])
    catalog.addTexts(group, live: [:], pending: ["en-US": LocalizationText(name: "Fruit Premium", customAppName: "Fruit")],
                     pendingState: .prepareForSubmission)
    return catalog
}

@Suite struct LocalizationTemplateTests {
    @Test func theTemplateHasOneRowPerOwnerAndLocaleWithTheEffectiveText() {
        let text = LocalizationTemplate.csv(snapshot: catalog().snapshot(), owners: [s, life, group])
        #expect(text.components(separatedBy: "\r\n") == [
            "product,locale,name,description,custom_app_name",
            "com.example.life,en-US,Fruit Lifetime,Forever,",
            "com.example.s,cs,Ovoce ročně,Všechno ovoce,",
            "com.example.s,en-US,Fruit Yearly,\"All fruit, every day\",",
            "group:Synthetic group,en-US,Fruit Premium,,Fruit",
            "",
        ])
    }

    @Test func rowsResolveProductIdsAscIdsAndGroupsAndNameWhatTheyCannot() {
        let snapshot = catalog().snapshot()
        let resolved = LocalizationTemplate.resolve([
            LocalizationTableRow(rowNumber: 2, product: "com.example.s", locale: "de-DE", name: "Obst"),
            LocalizationTableRow(rowNumber: 3, product: "life", locale: "cs", name: "Doživotně"),
            LocalizationTableRow(rowNumber: 4, product: "group:Synthetic group", locale: "cs", customAppName: "Ovoce"),
            LocalizationTableRow(rowNumber: 5, product: "com.example.nope", locale: "cs", name: "X"),
            LocalizationTableRow(rowNumber: 6, product: "group:Synthetic group", locale: "cs", description: "X"),
            LocalizationTableRow(rowNumber: 7, product: "com.example.s", locale: "cs", customAppName: "X"),
            LocalizationTableRow(rowNumber: 8, product: "group:Missing", locale: "cs", name: "X"),
            LocalizationTableRow(rowNumber: 9, product: "group:group-1", locale: "de-DE", customAppName: "Obst"),
        ], snapshot: snapshot)
        #expect(resolved.edits == [
            LocalizationEdit(owner: s, locale: "de-DE", name: "Obst"),
            LocalizationEdit(owner: life, locale: "cs", name: "Doživotně"),
            LocalizationEdit(owner: group, locale: "cs", customAppName: "Ovoce"),
            LocalizationEdit(owner: group, locale: "de-DE", customAppName: "Obst"),
        ])
        #expect(resolved.problems.count == 4)
        #expect(resolved.problems[0].hasPrefix("Row 5: "))
        #expect(resolved.problems[1].contains("no description"))
        #expect(resolved.problems[2].contains("custom app name"))
        #expect(resolved.problems[3].contains("“Missing”"))
    }

    @Test func anExportedTemplateImportedBackPlansNothing() async throws {
        let snapshot = catalog().snapshot()
        let text = LocalizationTemplate.csv(snapshot: snapshot, owners: snapshot.owners())
        let rows = try LocalizationTable.parse(try await CSVTableSource(data: Data(text.utf8)).fetchRows())
        let resolved = LocalizationTemplate.resolve(rows, snapshot: snapshot)
        #expect(resolved.problems.isEmpty)
        #expect(resolved.edits.count == 4)
        let draft = try plan(.localization(LocalizationPlanSpec(edits: resolved.edits)), snapshot)
        #expect(draft.items.isEmpty)
        #expect(draft.blocks.isEmpty)
    }

    @Test func groupsSharingANameAreNamedByAscIdAndResolveBack() async throws {
        var catalog = catalog()
        let other = LocalizationOwner.group("group-2")
        catalog.addGroup("group-2")
        catalog.addTexts(other, live: [:], pending: ["en-US": LocalizationText(name: "Fruit Basic", customAppName: "Basic")],
                         pendingState: .prepareForSubmission)
        let snapshot = catalog.snapshot()
        #expect(LocalizationTemplate.reference(group, snapshot: snapshot) == "group:group-1")
        #expect(LocalizationTemplate.reference(other, snapshot: snapshot) == "group:group-2")
        let text = LocalizationTemplate.csv(snapshot: snapshot, owners: [group, other])
        #expect(text.components(separatedBy: "\r\n") == [
            "product,locale,name,description,custom_app_name",
            "group:group-1,en-US,Fruit Premium,,Fruit",
            "group:group-2,en-US,Fruit Basic,,Basic",
            "",
        ])
        let rows = try LocalizationTable.parse(try await CSVTableSource(data: Data(text.utf8)).fetchRows())
        let resolved = LocalizationTemplate.resolve(rows, snapshot: snapshot)
        #expect(resolved.problems.isEmpty)
        #expect(resolved.edits.map(\.owner) == [group, other])
        #expect(try plan(.localization(LocalizationPlanSpec(edits: resolved.edits)), snapshot).items.isEmpty)

        let byName = LocalizationTemplate.resolve(
            [LocalizationTableRow(rowNumber: 2, product: "group:Synthetic group", locale: "cs", name: "X")], snapshot: snapshot)
        #expect(byName.edits.isEmpty)
        #expect(byName.problems.count == 1)
        #expect(byName.problems[0].hasPrefix("Row 2: "))
        #expect(byName.problems[0].contains("group:<ASC id>"))
    }

    @Test func aGroupNamedLikeAnotherGroupsAscIdIsNamedByItsOwnAscId() {
        var catalog = catalog()
        catalog.addGroup("group-1", name: "group-2")
        catalog.addGroup("group-2", name: "Other")
        let snapshot = catalog.snapshot()
        #expect(LocalizationTemplate.reference(.group("group-1"), snapshot: snapshot) == "group:group-1")
        #expect(LocalizationTemplate.reference(.group("group-2"), snapshot: snapshot) == "group:Other")
        #expect(LocalizationTemplate.reference(.group("nope"), snapshot: snapshot) == nil)
    }

    @Test func theGroupPrefixIsReadWhateverItsCase() {
        let snapshot = catalog().snapshot()
        #expect(LocalizationTemplate.owner(for: "Group:Synthetic group", snapshot: snapshot).owner == group)
        #expect(LocalizationTemplate.owner(for: "GROUP: group-1 ", snapshot: snapshot).owner == group)
    }

    @Test func aReferenceThatNamesMoreThanOneProductIsRefusedAndTheProductsAreNamedByAscId() async throws {
        var catalog = catalog()
        // The Product ID of the subscription "s" is the ASC id of the in-app purchase "life".
        catalog.subscriptions["s"]?.productId = "life"
        let snapshot = catalog.snapshot()
        let found = LocalizationTemplate.owner(for: "life", snapshot: snapshot)
        #expect(found.owner == nil)
        #expect(found.problem == "more than one product is named “life”; name it by its ASC id")
        #expect(LocalizationTemplate.owner(for: "s", snapshot: snapshot).owner == s)
        #expect(LocalizationTemplate.owner(for: "com.example.life", snapshot: snapshot).owner == life)

        #expect(LocalizationTemplate.reference(s, snapshot: snapshot) == "s")
        #expect(LocalizationTemplate.reference(life, snapshot: snapshot) == "com.example.life")
        let text = LocalizationTemplate.csv(snapshot: snapshot, owners: [s, life])
        #expect(text.contains("\r\ns,en-US,"))
        let rows = try LocalizationTable.parse(try await CSVTableSource(data: Data(text.utf8)).fetchRows())
        let resolved = LocalizationTemplate.resolve(rows, snapshot: snapshot)
        #expect(resolved.problems.isEmpty)
        #expect(Set(resolved.edits.map(\.owner)) == [s, life])
        #expect(try plan(.localization(LocalizationPlanSpec(edits: resolved.edits)), snapshot).items.isEmpty)

        let byName = LocalizationTemplate.resolve([LocalizationTableRow(rowNumber: 4, product: "life", locale: "cs", name: "X")], snapshot: snapshot)
        #expect(byName.edits.isEmpty)
        #expect(byName.problems == ["Row 4: more than one product is named “life”; name it by its ASC id."])
    }

    @Test func twoProductsSharingAProductIdAreNamedByAscId() async throws {
        var catalog = catalog()
        catalog.addSubscription("s2", prices: ["USA": d("9.99")], period: .oneMonth)
        catalog.subscriptions["s2"]?.productId = "com.example.s"
        catalog.addTexts(.subscription("s2"), live: ["en-US": LocalizationText(name: "Fruit Monthly", description: "Every month")])
        let snapshot = catalog.snapshot()
        #expect(LocalizationTemplate.owner(for: "com.example.s", snapshot: snapshot).owner == nil)
        #expect(LocalizationTemplate.reference(s, snapshot: snapshot) == "s")
        #expect(LocalizationTemplate.reference(.subscription("s2"), snapshot: snapshot) == "s2")
        let text = LocalizationTemplate.csv(snapshot: snapshot, owners: snapshot.owners())
        let rows = try LocalizationTable.parse(try await CSVTableSource(data: Data(text.utf8)).fetchRows())
        let resolved = LocalizationTemplate.resolve(rows, snapshot: snapshot)
        #expect(resolved.problems.isEmpty)
        #expect(Set(resolved.edits.map(\.owner)) == [s, .subscription("s2"), life, group])
        #expect(try plan(.localization(LocalizationPlanSpec(edits: resolved.edits)), snapshot).items.isEmpty)
    }

    @Test func aProductWhoseReadableNameCannotBeResolvedBackIsNamedByAscId() {
        var catalog = catalog()
        catalog.subscriptions["s"]?.productId = ""
        let snapshot = catalog.snapshot()
        #expect(LocalizationTemplate.reference(s, snapshot: snapshot) == "s")
        #expect(LocalizationTemplate.reference(life, snapshot: snapshot) == "com.example.life")
        #expect(LocalizationTemplate.reference(.iap("nope"), snapshot: snapshot) == nil)
        catalog.iaps["life"]?.productId = " padded "   // the table and the tools trim what they read
        #expect(LocalizationTemplate.reference(life, snapshot: catalog.snapshot()) == "life")
    }
}
