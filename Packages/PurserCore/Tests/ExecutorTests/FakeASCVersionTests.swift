import Foundation
import Testing
import Domain
import ASCClient
import PurserTestSupport

/// L3: FakeASC's version creation. An assumption until spike SL10n (docs/spikes/SL10n.md) confirms it.
@Suite("FakeASC: new versions (L3)")
struct FakeASCVersionTests {
    let yearly = LocalizationOwner.subscription("sub-y")      // ver-sub-y-1 APPROVED with en-US and cs (FakeSeed)

    func liveVersion(_ model: FakeModel, _ owner: LocalizationOwner) throws -> FakeVersion {
        try #require(model.versions.filter { $0.owner == owner && $0.state.role == .live }.max { $0.number < $1.number })
    }

    @Test func aPostCopiesTheLiveTextsIntoTheNextVersion() async throws {
        let h = try await ExecutorHarness.make()
        await h.fake.setNewVersionCopiesLocalizations(true)
        let before = await h.fake.model
        let live = try liveVersion(before, yearly)
        let created = try await h.writer.createMetadataVersion(owner: yearly)
        #expect(created.owner == yearly)
        #expect(created.number == live.number + 1)
        #expect(created.state == .prepareForSubmission)
        let model = await h.fake.model
        let liveRows = model.localizations.filter { $0.versionId == live.id }
        let copied = model.localizations.filter { $0.versionId == created.ascId }
        #expect(!liveRows.isEmpty)
        #expect(Set(copied.map(\.locale)) == Set(liveRows.map(\.locale)))
        #expect(Set(copied.map(\.text)) == Set(liveRows.map(\.text)))
        #expect(Set(copied.map(\.id)).isDisjoint(with: liveRows.map(\.id)))
        #expect(liveRows == before.localizations.filter { $0.versionId == live.id })
    }

    @Test func aSecondVersionIsRefusedWhileOneIsPending() async throws {
        let h = try await ExecutorHarness.make()
        _ = try await h.writer.createMetadataVersion(owner: yearly)
        let count = await h.fake.model.versions.count
        do {
            _ = try await h.writer.createMetadataVersion(owner: yearly)
            Issue.record("a second pending version was created")
        } catch let ASCError.http(status, code, _, _) {
            #expect(status == 409)
            #expect(code == "ENTITY_ERROR.STATE_INVALID")
        }
        #expect(await h.fake.model.versions.count == count)
    }

    @Test func anOwnerWithAnEditableFirstVersionGetsNoOther() async throws {
        let h = try await ExecutorHarness.make()
        let count = await h.fake.model.versions.count
        await #expect(throws: ASCError.self) { _ = try await h.writer.createMetadataVersion(owner: .subscription("sub-n")) }
        #expect(await h.fake.model.versions.count == count)
    }

    @Test func groupAndInAppPurchaseGetVersionsToo() async throws {
        let h = try await ExecutorHarness.make()
        _ = try await h.initialSync()          // the group becomes a known child of the app (AppGuard)
        await h.fake.setNewVersionCopiesLocalizations(true)
        let group = LocalizationOwner.group("grp-1")
        let lifetime = LocalizationOwner.iap("iap-life")
        let before = await h.fake.model
        let groupLive = try liveVersion(before, group)
        let iapLive = try liveVersion(before, lifetime)
        let groupVersion = try await h.writer.createMetadataVersion(owner: group)
        let iapVersion = try await h.writer.createMetadataVersion(owner: lifetime)
        #expect(groupVersion.number == groupLive.number + 1)
        #expect(iapVersion.number == iapLive.number + 1)
        let model = await h.fake.model
        #expect(model.localizations.contains { $0.versionId == groupVersion.ascId && $0.locale == "en-US" && $0.text.customAppName == "FruitJar" })
        #expect(model.localizations.contains { $0.versionId == iapVersion.ascId && $0.locale == "en-US" })
        #expect(await h.fake.writeRequests().map(\.path) == ["/v1/subscriptionGroupVersions", "/v1/inAppPurchaseVersions"])
    }

    @Test func copyingCanBeSwitchedOffForTheOtherAnswerOfTheSpike() async throws {
        let h = try await ExecutorHarness.make()
        await h.fake.setNewVersionCopiesLocalizations(false)
        let created = try await h.writer.createMetadataVersion(owner: yearly)
        #expect(await h.fake.model.localizations.filter { $0.versionId == created.ascId }.isEmpty)
    }

    @Test func aReadShowsTheNewVersionAsPendingWithItsTexts() async throws {
        let h = try await ExecutorHarness.make()
        await h.fake.setNewVersionCopiesLocalizations(true)
        let created = try await h.writer.createMetadataVersion(owner: yearly)
        let metadata = try await h.reader.metadata(owner: yearly)
        #expect(metadata.pendingVersion?.ascId == created.ascId)
        #expect(metadata.pendingVersion?.state.role == .editable)
        let live = try #require(metadata.liveVersion)
        #expect(metadata.localizations.filter { $0.versionId == created.ascId }.map(\.locale)
                == metadata.localizations.filter { $0.versionId == live.ascId }.map(\.locale))
    }
}
