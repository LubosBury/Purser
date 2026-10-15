import Foundation
import Testing
import Domain
import ASCClient
import PurserTestSupport

private struct MissingFixture: Error { let what: String }

private func send(_ fake: FakeASC, _ method: String, _ path: String, body: String? = nil) async throws -> (status: Int, json: [String: Any]) {
    var request = URLRequest(url: URL(string: "https://api.appstoreconnect.apple.com\(path)")!)
    request.httpMethod = method
    request.httpBody = body.map { Data($0.utf8) }
    request.setValue("Bearer " + (try WriteTestClients.signer().token(scope: nil, now: Date())), forHTTPHeaderField: "Authorization")
    let (data, response) = try await fake.send(request)
    let json = data.isEmpty ? [:] : ((try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
    return (response.statusCode, json)
}

private func errorCode(_ json: [String: Any]) -> String? {
    ((json["errors"] as? [[String: Any]])?.first?["code"]) as? String
}

private func create(_ collection: String, versionType: String, version: String, locale: String, name: String, extra: String = "") -> String {
    #"{"data":{"type":"\#(collection)","attributes":{"locale":"\#(locale)","name":"\#(name)"\#(extra)},"relationships":{"version":{"data":{"type":"\#(versionType)","id":"\#(version)"}}}}}"#
}

private func patch(_ collection: String, id: String, attributes: String) -> String {
    #"{"data":{"type":"\#(collection)","id":"\#(id)","attributes":{\#(attributes)}}}"#
}

@Suite("FakeASC localization writes")
struct FakeASCLocalizationWriteTests {
    let clock = TestClock.at("2026-10-09T08:00:00Z")

    func version(_ fake: FakeASC, _ owner: LocalizationOwner, editable: Bool) async throws -> FakeVersion {
        let model = await fake.model
        guard let version = model.versions.last(where: { $0.owner == owner && ($0.state.role == .editable) == editable }) else {
            throw MissingFixture(what: "version of \(owner)")
        }
        return version
    }

    func row(_ fake: FakeASC, version: String, locale: String) async throws -> FakeLocalization {
        let model = await fake.model
        guard let row = model.localizations.first(where: { $0.versionId == version && $0.locale == locale }) else {
            throw MissingFixture(what: "\(locale) in \(version)")
        }
        return row
    }

    @Test func aPostIntoTheEditableVersionAddsTheLocaleAndReadsShowIt() async throws {
        let fake = FakeASC(model: FakeSeed.fruitJar(), now: clock.nowFunction)
        let draft = try await version(fake, .subscription("sub-n"), editable: true)
        let reply = try await send(fake, "POST", "/v2/subscriptionLocalizations",
                                   body: create("subscriptionLocalizations", versionType: "subscriptionVersions", version: draft.id, locale: "cs",
                                                name: "Ročně nové", extra: #","description":"Celý rok ovoce""#))
        #expect(reply.status == 201)
        let created = try await row(fake, version: draft.id, locale: "cs")
        #expect(((reply.json["data"] as? [String: Any])?["id"]) as? String == created.id)
        #expect(created.text.description == "Celý rok ovoce")
        let reader = LiveASCClient(http: try await WriteTestClients.http(transport: fake, readOnly: true, products: ["sub-n"], now: clock.nowFunction))
        let metadata = try await reader.metadata(owner: .subscription("sub-n"))
        #expect(metadata.localizations.contains { $0.ascId == created.id && $0.locale == "cs" && $0.text.name == "Ročně nové" })
    }

    @Test func aPatchChangesOnlyTheFieldsItSends() async throws {
        let fake = FakeASC(model: FakeSeed.fruitJar(), now: clock.nowFunction)
        let draft = try await version(fake, .subscription("sub-n"), editable: true)
        let before = try await row(fake, version: draft.id, locale: "en-US")
        let reply = try await send(fake, "PATCH", "/v2/subscriptionLocalizations/\(before.id)",
                                   body: patch("subscriptionLocalizations", id: before.id, attributes: #""name":"Fruit Yearly Plus""#))
        #expect(reply.status == 200)
        let after = try await row(fake, version: draft.id, locale: "en-US")
        #expect(after.text.name == "Fruit Yearly Plus")
        #expect(after.text.description == before.text.description)
    }

    @Test func aLiveVersionAnswers409() async throws {
        let fake = FakeASC(model: FakeSeed.fruitJar(), now: clock.nowFunction)
        let live = try await version(fake, .subscription("sub-y"), editable: false)
        let post = try await send(fake, "POST", "/v2/subscriptionLocalizations",
                                  body: create("subscriptionLocalizations", versionType: "subscriptionVersions", version: live.id, locale: "de-DE", name: "Obst"))
        #expect(post.status == 409)
        #expect(errorCode(post.json) == "ENTITY_ERROR.STATE_INVALID")
        let english = try await row(fake, version: live.id, locale: "en-US")
        let change = try await send(fake, "PATCH", "/v2/subscriptionLocalizations/\(english.id)",
                                    body: patch("subscriptionLocalizations", id: english.id, attributes: #""name":"Changed""#))
        #expect(change.status == 409)
        #expect(errorCode(change.json) == "ENTITY_ERROR.STATE_INVALID")
    }

    @Test func aDuplicateUnknownOrTooLongTextAnswers409() async throws {
        let fake = FakeASC(model: FakeSeed.fruitJar(), now: clock.nowFunction)
        let draft = try await version(fake, .subscription("sub-n"), editable: true)
        func post(_ locale: String, _ name: String) async throws -> (status: Int, json: [String: Any]) {
            try await send(fake, "POST", "/v2/subscriptionLocalizations",
                           body: create("subscriptionLocalizations", versionType: "subscriptionVersions", version: draft.id, locale: locale, name: name))
        }
        let duplicate = try await post("en-US", "Again")
        #expect(duplicate.status == 409)
        #expect(errorCode(duplicate.json) == "ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE")
        #expect(errorCode(try await post("xx-XX", "Unknown").json) == "ENTITY_ERROR.ATTRIBUTE.INVALID")
        #expect(try await post("de-DE", String(repeating: "a", count: 31)).status == 409)
        #expect(try await post("de-DE", String(repeating: "a", count: 30)).status == 201)
    }

    @Test func aGroupTakesACustomAppNameAndRefusesADescription() async throws {
        let group = LocalizationOwner.group("grp-1")
        let fake = FakeASC(model: FakeSeed.fruitJar(), now: clock.nowFunction)
        await fake.mutate { model in
            for index in model.versions.indices where model.versions[index].owner == group { model.versions[index].state = .prepareForSubmission }
        }
        let draft = try await version(fake, group, editable: true)
        let refused = try await send(fake, "POST", "/v2/subscriptionGroupLocalizations",
                                     body: create("subscriptionGroupLocalizations", versionType: "subscriptionGroupVersions", version: draft.id,
                                                  locale: "cs", name: "Ovoce Premium", extra: #","description":"No""#))
        #expect(refused.status == 409)
        let created = try await send(fake, "POST", "/v2/subscriptionGroupLocalizations",
                                     body: create("subscriptionGroupLocalizations", versionType: "subscriptionGroupVersions", version: draft.id,
                                                  locale: "cs", name: "Ovoce Premium", extra: #","customAppName":"Ovoce""#))
        #expect(created.status == 201)
        let attributes = (created.json["data"] as? [String: Any])?["attributes"] as? [String: Any]
        #expect(attributes?["customAppName"] as? String == "Ovoce")
        #expect(try await row(fake, version: draft.id, locale: "cs").text.customAppName == "Ovoce")
    }

    @Test func theLocaleCannotChangeAndThereIsNoDelete() async throws {
        let fake = FakeASC(model: FakeSeed.fruitJar(), now: clock.nowFunction)
        let draft = try await version(fake, .subscription("sub-n"), editable: true)
        let english = try await row(fake, version: draft.id, locale: "en-US")
        let moved = try await send(fake, "PATCH", "/v2/subscriptionLocalizations/\(english.id)",
                                   body: patch("subscriptionLocalizations", id: english.id, attributes: #""locale":"cs""#))
        #expect(moved.status == 409)
        // L-D4: Purser never deletes a locale, so FakeASC does not model the DELETE.
        #expect(try await send(fake, "DELETE", "/v2/subscriptionLocalizations/\(english.id)").status == 404)
        let after = await fake.model
        #expect(after.localizations.contains { $0.id == english.id })
    }
}
