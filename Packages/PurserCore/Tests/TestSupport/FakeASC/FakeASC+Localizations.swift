import Foundation
import Domain
import ASCClient

/// Localization writes (L2): POST and PATCH of v2 localizations, only in a version with role .editable. No DELETE (L-D4).
/// Reads, `localizationType(_:)` and `localizationResource(_:kind:)` live in FakeASC+Metadata.swift.
/// Assumptions until spike SL10n: a locked version, a duplicate or unknown locale, a text outside the AppleConstants limits,
/// a foreign attribute and a change of the locale answer 409.
extension FakeASC {
    static let writtenLocalizationKinds: [String: LocalizationOwnerKind] = Dictionary(
        uniqueKeysWithValues: LocalizationOwnerKind.allCases.map { (FakeASC.localizationType($0), $0) })

    /// The attribute next to `name`: customAppName for a group, description otherwise.
    static func secondTextKey(_ kind: LocalizationOwnerKind) -> String { kind == .group ? "customAppName" : "description" }

    /// nil when `path` is not a v2 localization path.
    func handleLocalizationWrite(method: String, path: String, body: Data?) throws -> FakeReply? {
        let c = components(path)
        guard c.count >= 2, c[0] == "v2", let kind = Self.writtenLocalizationKinds[c[1]] else { return nil }
        switch (method, c.count) {
        case ("POST", 2): return try postLocalization(kind, body)
        case ("PATCH", 3): return try patchLocalization(kind, id: c[2], body)
        default: throw notFound()
        }
    }

    func editableVersion(_ id: String?, kind: LocalizationOwnerKind) throws -> FakeVersion {
        guard let id, let version = model.versions.first(where: { $0.id == id }), version.owner.kind == kind else {
            throw conflict("ENTITY_ERROR.RELATIONSHIP.INVALID", "The version does not exist")
        }
        guard version.state.role == .editable else {
            throw conflict("ENTITY_ERROR.STATE_INVALID", "The version is \(version.state.rawValue) and cannot be edited")
        }
        return version
    }

    func checkLocalizedText(_ kind: LocalizationOwnerKind, name: String, second: String?) throws {
        guard !name.isEmpty else { throw conflict("ENTITY_ERROR.ATTRIBUTE.REQUIRED", "name is required") }
        guard let limits = AppleConstants.localizationLimits[kind] ?? nil else { return }
        if name.count < limits.nameMin || name.count > limits.nameMax {
            throw conflict("ENTITY_ERROR.ATTRIBUTE.INVALID", "name must have \(limits.nameMin) to \(limits.nameMax) characters")
        }
        if let second, second.count > limits.descriptionMax {
            throw conflict("ENTITY_ERROR.ATTRIBUTE.INVALID", "description must have at most \(limits.descriptionMax) characters")
        }
    }

    func postLocalization(_ kind: LocalizationOwnerKind, _ body: Data?) throws -> FakeReply {
        let (data, _) = try parse(body)
        let a = attributes(data)
        if let extra = Set(a.keys).subtracting(["name", "locale", Self.secondTextKey(kind)]).sorted().first {
            throw conflict("ENTITY_ERROR.ATTRIBUTE.INVALID", "The attribute '\(extra)' is not allowed")
        }
        guard let name = a["name"] as? String, let locale = a["locale"] as? String else {
            throw conflict("ENTITY_ERROR.ATTRIBUTE.REQUIRED", "name and locale are required")
        }
        guard AppleConstants.localizationLocales.contains(locale) else {
            throw conflict("ENTITY_ERROR.ATTRIBUTE.INVALID", "The locale '\(locale)' is not valid")
        }
        let second = a[Self.secondTextKey(kind)] as? String
        try checkLocalizedText(kind, name: name, second: second)
        let version = try editableVersion(relId(data, "version"), kind: kind)
        if model.localizations.contains(where: { $0.versionId == version.id && $0.locale == locale }) {
            throw conflict("ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE", "A localization for \(locale) already exists in this version")
        }
        let row = FakeLocalization(id: nextId("loc"), versionId: version.id, locale: locale,
                                   text: LocalizationText(name: name, description: kind == .group ? nil : second,
                                                          customAppName: kind == .group ? second : nil))
        model.localizations.append(row)
        return FakeReply(status: 201, body: single(localizationResource(row, kind: kind)), applied: true)
    }

    func patchLocalization(_ kind: LocalizationOwnerKind, id: String, _ body: Data?) throws -> FakeReply {
        guard let index = model.localizations.firstIndex(where: { $0.id == id }) else { throw notFound() }
        let (data, _) = try parse(body)
        let a = attributes(data)
        if a.keys.contains("locale") { throw conflict("ENTITY_ERROR.ATTRIBUTE.INVALID", "The locale cannot be changed") }
        if let extra = Set(a.keys).subtracting(["name", Self.secondTextKey(kind)]).sorted().first {
            throw conflict("ENTITY_ERROR.ATTRIBUTE.INVALID", "The attribute '\(extra)' is not allowed")
        }
        var row = model.localizations[index]
        _ = try editableVersion(row.versionId, kind: kind)
        let name = a["name"] as? String ?? row.text.name
        let current = kind == .group ? row.text.customAppName : row.text.description
        let second: String? = a.keys.contains(Self.secondTextKey(kind)) ? a[Self.secondTextKey(kind)] as? String : current
        try checkLocalizedText(kind, name: name, second: second)
        row.text.name = name
        if kind == .group { row.text.customAppName = second } else { row.text.description = second }
        model.localizations[index] = row
        return FakeReply(status: 200, body: single(localizationResource(row, kind: kind)), applied: true)
    }
}
