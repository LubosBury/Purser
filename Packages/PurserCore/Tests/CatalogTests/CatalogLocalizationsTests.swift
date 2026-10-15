import Foundation
import Testing
import Catalog
import Domain
import PurserTestSupport

@Suite struct CatalogLocalizationsTests {
    private let owner = LocalizationOwner.subscription("s")

    private func catalog() -> SyntheticCatalog {
        var catalog = SyntheticCatalog()
        catalog.addSubscription("s", prices: ["USA": SyntheticCatalog.d("29.99")])
        catalog.addGroup()
        return catalog
    }

    @Test func liveAndPendingTextsSideBySideWithTheirChange() {
        var catalog = catalog()
        catalog.addTexts(owner, live: ["en-US": LocalizationText(name: "Yearly", description: "Every fruit"),
                                       "cs": LocalizationText(name: "Ročně", description: "Ovoce"),
                                       "fr-FR": LocalizationText(name: "Annuel")],
                         pending: ["en-US": LocalizationText(name: "Yearly Plus", description: "Every fruit"),
                                   "cs": LocalizationText(name: "Ročně", description: "Ovoce"),
                                   "de-DE": LocalizationText(name: "Jährlich")],
                         pendingState: .waitingForReview)
        let section = CatalogLocalizations.of(owner, snapshot: catalog.snapshot())
        #expect(section.liveVersion?.number == 1)
        #expect(section.pendingVersion?.state == .waitingForReview)
        #expect(section.rows.map(\.locale) == ["cs", "de-DE", "en-US", "fr-FR"])
        #expect(section.rows.map(\.change) == [.none, .added, .changed, .removed])
        #expect(section.rows[0].cell == .localization(owner: owner, locale: "cs"))
        #expect(section.rows[1].live == nil)
        #expect(section.rows[2].pending?.name == "Yearly Plus")
        #expect(section.rows[3].pending == nil)
    }

    @Test func withoutAPendingVersionNothingIsMarked() {
        var catalog = catalog()
        catalog.addTexts(owner, live: ["en-US": LocalizationText(name: "Yearly", description: "Every fruit")])
        let section = CatalogLocalizations.of(owner, snapshot: catalog.snapshot())
        #expect(section.pendingVersion == nil)
        #expect(section.rows.map(\.change) == [.none])
    }

    @Test func aNeverSubmittedProductShowsOnlyItsDraft() {
        var catalog = catalog()
        catalog.addTexts(owner, live: [:], pending: ["en-US": LocalizationText(name: "Yearly")], pendingState: .prepareForSubmission)
        let section = CatalogLocalizations.of(owner, snapshot: catalog.snapshot())
        #expect(section.liveVersion == nil)
        #expect(section.pendingVersion?.number == 1)
        #expect(section.rows.map(\.change) == [.added])
    }

    @Test func aGroupKeepsItsCustomAppNameAndAnUnreadOwnerIsEmpty() {
        var catalog = catalog()
        catalog.addTexts(.group("group-1"), live: ["en-US": LocalizationText(name: "Premium", customAppName: "Fruit")])
        let snapshot = catalog.snapshot()
        #expect(CatalogLocalizations.of(.group("group-1"), snapshot: snapshot).rows.first?.live?.customAppName == "Fruit")
        let unread = CatalogLocalizations.of(.iap("life"), snapshot: snapshot)
        #expect(unread.rows.isEmpty)
        #expect(unread.liveVersion == nil && unread.pendingVersion == nil)
    }
}
