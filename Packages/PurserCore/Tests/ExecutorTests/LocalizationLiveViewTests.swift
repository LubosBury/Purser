import Foundation
import Testing
import Domain
import Catalog
@testable import Executor
import PurserTestSupport

@Suite("Localization live view")
struct LocalizationLiveViewTests {
    private let owner = LocalizationOwner.subscription("sub-y")

    private func metadata(_ name: String) -> OwnerMetadata {
        OwnerMetadata(owner: owner, versions: [MetadataVersion(ascId: "ver-1", owner: owner, number: 1, state: .approved)],
                      localizations: [LocalizationRow(ascId: "loc-1", owner: owner, versionId: "ver-1", locale: "en-US",
                                                      text: LocalizationText(name: name, description: "Every fruit"))])
    }

    @Test func freshMetadataReplacesTheOwnerAndDropsItsOverrides() {
        let cell = CellKey.localization(owner: owner, locale: "en-US")
        let other = CellKey.localization(owner: .group("grp-1"), locale: "en-US")
        let snapshot = CatalogSnapshot(syncId: 1, takenAt: Date(), subscriptions: [:], iaps: [:], territories: [:], regularRows: [],
                                       introRows: [], promoOffers: [], iapSchedules: [:], pricePoints: PricePointIndex([]),
                                       offerCodesEverSeen: [], groups: ["grp-1": SubscriptionGroupInfo(ascId: "grp-1", referenceName: "Premium")],
                                       metadata: [owner: metadata("Yearly")])
        let today = CalendarDate(iso: "2026-10-09")!
        var view = LiveView(snapshot: snapshot)
        #expect(view.state(cell, today: today) == .localization(live: metadata("Yearly").localizations.first, pending: nil, pendingVersion: nil))
        view.set(cell, .localization(live: nil, pending: nil, pendingVersion: nil))
        view.set(other, .localization(live: nil, pending: nil, pendingVersion: nil))
        view.apply(.metadata(metadata("Yearly Plus")))
        #expect(view.state(cell, today: today) == .localization(live: metadata("Yearly Plus").localizations.first, pending: nil, pendingVersion: nil))
        #expect(view.state(other, today: today) == .localization(live: nil, pending: nil, pendingVersion: nil))
        #expect(view.snapshot.groups["grp-1"]?.referenceName == "Premium")
    }

    @Test func aTextCellIsReadFreshWithTheOwnersVersions() async throws {
        let h = try await ExecutorHarness.make()
        let snapshot = try await h.initialSync()
        #expect(snapshot.groups["grp-1"]?.referenceName == "Premium")
        #expect(snapshot.locales(of: owner) == ["cs", "en-US"])
        #expect(snapshot.pendingVersion(of: .subscription("sub-n"))?.state == .prepareForSubmission)
        let fresh = try await CellReader(reader: h.reader).read(.localization(owner: owner, locale: "cs"), in: snapshot)
        guard case let .metadata(read) = fresh else { Issue.record("expected metadata, got \(fresh)"); return }
        #expect(read == snapshot.metadata[owner])
        #expect(await h.fake.writeRequests().isEmpty)
    }
}
