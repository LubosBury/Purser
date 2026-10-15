import Foundation
import Testing
import Domain
@testable import Executor
import PurserTestSupport

private let owner = LocalizationOwner.subscription("sub-1")

private func metadata(versionId: String, locales: [String]) -> OwnerMetadata {
    OwnerMetadata(owner: owner, versions: [MetadataVersion(ascId: versionId, owner: owner, number: 2, state: .prepareForSubmission)],
                  localizations: locales.map {
                      LocalizationRow(ascId: "loc-\($0)", owner: owner, versionId: versionId, locale: $0, text: LocalizationText(name: $0))
                  })
}

@Suite struct LocalizationResolverTests {
    @Test func idsKnownAtPlanningTimeNeedNoRead() async throws {
        let reads = Locked(0)
        let patch = SetLocalization(owner: owner, locale: "en-US", text: LocalizationText(name: "A"), localizationId: "loc-1", versionId: "ver-1")
        let post = SetLocalization(owner: owner, locale: "cs", text: LocalizationText(name: "B"), localizationId: nil, versionId: "ver-1")
        let first = try await LocalizationResolver.resolve(patch, createdVersions: [:]) {
            reads.update { $0 += 1 }
            return metadata(versionId: "ver-1", locales: [])
        }
        let second = try await LocalizationResolver.resolve(post, createdVersions: [:]) {
            reads.update { $0 += 1 }
            return metadata(versionId: "ver-1", locales: [])
        }
        #expect(first == .update(localizationId: "loc-1"))
        #expect(second == .create(versionId: "ver-1"))
        #expect(reads.value == 0)
    }

    @Test func withoutIdsTheCreatedVersionIsReadOnce() async throws {
        let reads = Locked(0)
        let copied = SetLocalization(owner: owner, locale: "en-US", text: LocalizationText(name: "A"), localizationId: nil, versionId: nil)
        let resolved = try await LocalizationResolver.resolve(copied, createdVersions: [owner: "ver-2"]) {
            reads.update { $0 += 1 }
            return metadata(versionId: "ver-2", locales: ["en-US"])
        }
        #expect(resolved == .update(localizationId: "loc-en-US"))
        var fresh = copied
        fresh.locale = "cs"
        let created = try await LocalizationResolver.resolve(fresh, createdVersions: [owner: "ver-2"]) {
            reads.update { $0 += 1 }
            return metadata(versionId: "ver-2", locales: ["en-US"])
        }
        #expect(created == .create(versionId: "ver-2"))
        #expect(reads.value == 2)
    }

    @Test func aReadThatDoesNotShowTheCreatedVersionYetResolvesNothing() async throws {
        // A row of an older version for the locale must not turn into a POST into a version the read does not show.
        let text = SetLocalization(owner: owner, locale: "en-US", text: LocalizationText(name: "A"), localizationId: nil, versionId: nil)
        await #expect(throws: LocalizationResolverError.versionNotVisible(owner, versionId: "ver-3")) {
            _ = try await LocalizationResolver.resolve(text, createdVersions: [owner: "ver-3"]) { metadata(versionId: "ver-2", locales: ["en-US"]) }
        }
    }

    @Test func withoutIdsAndWithoutACreatedVersionItThrows() async throws {
        let text = SetLocalization(owner: owner, locale: "cs", text: LocalizationText(name: "B"), localizationId: nil, versionId: nil)
        await #expect(throws: LocalizationResolverError.noVersion(owner)) {
            _ = try await LocalizationResolver.resolve(text, createdVersions: [:]) { metadata(versionId: "ver-2", locales: []) }
        }
    }
}
