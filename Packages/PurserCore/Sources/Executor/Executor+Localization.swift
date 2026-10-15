import Foundation
import Domain
import ASCClient

/// What one item sends: the route and body audited in httpSent, and for a text the resolved request.
struct PreparedRequest: Sendable {
    var method: String
    var path: String
    var body: Data?
    var localization: LocalizationRequest?
}

extension Executor {
    /// Versions done createMetadataVersion items of `planId` created, by owner.
    func createdVersions(_ planId: String) -> [LocalizationOwner: String] { Self.createdVersions(in: ledgers[planId] ?? [:]) }

    /// The route and body of an item. A SET_TEXT item is resolved first and built from the localization writes of WritePaths
    /// and WriteBodies, so httpSent carries the real method, path and body. An owner read during the resolution goes into
    /// `context.freshMetadata` and `context.view` once the resolver accepted it (it shows the created version): at most one
    /// read per owner and run. A failed read throws its ASCError; `process` waits and tries the item again.
    func prepare(_ item: PlannedItem, planId: String, context: inout RunContext) async throws -> PreparedRequest {
        guard case let .setLocalization(text) = item.payload else {
            let route = WritePaths.request(for: item.payload)
            return PreparedRequest(method: route.method, path: route.path, body: try WriteBodies.body(for: item.payload)?.data(), localization: nil)
        }
        let owner = text.owner
        var read: OwnerMetadata?
        let resolved = try await LocalizationResolver.resolve(text, createdVersions: createdVersions(planId)) {
            if let cached = context.freshMetadata[owner] { return cached }
            let fresh = try await self.reader.metadata(owner: owner)
            read = fresh
            return fresh
        }
        if let read {
            context.freshMetadata[owner] = read
            context.view.apply(.metadata(read))
        }
        switch resolved {
        case let .create(versionId):
            let route = WritePaths.createLocalization(owner.kind)
            let body = try WriteBodies.createLocalization(versionId: versionId, owner: owner, locale: text.locale, text: text.text).data()
            return PreparedRequest(method: route.method, path: route.path, body: body, localization: resolved)
        case let .update(localizationId):
            let route = WritePaths.updateLocalization(owner.kind, id: localizationId)
            let body = try WriteBodies.updateLocalization(localizationId: localizationId, owner: owner, text: text.text).data()
            return PreparedRequest(method: route.method, path: route.path, body: body, localization: resolved)
        }
    }
}
