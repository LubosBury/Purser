import Foundation
import Testing
import Domain

/// Natural keys are persisted (item.natural_key), so these strings are golden.
@Suite struct LocalizationPayloadTests {
    let subscription = LocalizationOwner.subscription("6500000001")
    let group = LocalizationOwner.group("7000000001")

    @Test func textKeysHashTheWholeTextAndIgnoreTheIds() {
        let patch = SetLocalization(owner: subscription, locale: "en-US",
                                    text: LocalizationText(name: "Fruit Yearly", description: "All fruit, every day"),
                                    localizationId: "loc-1", versionId: nil)
        #expect(NaturalKey.of(.setLocalization(patch))
                == "T=|S|6500000001|en-US|df3ee6abd004695ea0403f9aacf3eaa16315547bc795d289a394a3f1872bf9ec")
        var post = patch
        post.localizationId = nil
        post.versionId = "ver-9"
        #expect(NaturalKey.of(.setLocalization(post)) == NaturalKey.of(.setLocalization(patch)))
        let groupText = SetLocalization(owner: group, locale: "cs", text: LocalizationText(name: "Ovoce Premium", customAppName: "Ovoce"),
                                        localizationId: nil, versionId: "ver-9")
        #expect(NaturalKey.of(.setLocalization(groupText))
                == "T=|G|7000000001|cs|499cd4199927ee19711c5bc08acaad31075c7a38f11cfde840ff17df8da25419")
    }

    @Test func opAndOriginHaveTheirStoredNames() {
        let payload = WritePayload.setLocalization(SetLocalization(owner: subscription, locale: "cs", text: LocalizationText(name: "Ovoce"),
                                                                   localizationId: nil, versionId: "ver-1"))
        #expect(payload.op == .setText)
        #expect(ItemOp.setText.rawValue == "SET_TEXT")
        #expect(PlanOrigin.localization.rawValue == "L10N")
        #expect(PlanOrigin(rawValue: "L10N") == .localization)
    }

    @Test func aTextItemRoundTripsThroughJSON() throws {
        let cell = CellKey.localization(owner: subscription, locale: "cs")
        let version = MetadataVersion(ascId: "ver-1", owner: subscription, number: 1, state: .prepareForSubmission)
        let row = LocalizationRow(ascId: "", owner: subscription, versionId: "ver-1", locale: "cs",
                                  text: LocalizationText(name: "Ovoce", description: "Všechno ovoce"))
        let item = PlannedItem(seq: 1, cell: cell,
                               payload: .setLocalization(SetLocalization(owner: subscription, locale: "cs", text: row.text,
                                                                         localizationId: nil, versionId: "ver-1")),
                               before: .localization(live: nil, pending: nil, pendingVersion: version),
                               target: .localization(live: nil, pending: row, pendingVersion: version), rules: ["N1", "N2"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let back = try JSONDecoder().decode(PlannedItem.self, from: encoder.encode(item))
        #expect(back == item)
        #expect(back.naturalKey == NaturalKey.of(item.payload))
    }

    @Test func provisionalLocalizationConstants() throws {
        #expect(AppleConstants.localizationLocales.count == 50)
        #expect(AppleConstants.localizationLocales.isSuperset(of: ["en-US", "cs", "de-DE", "zh-Hans", "pt-BR"]))
        let subscription = try #require(AppleConstants.localizationLimits[.subscription] ?? nil)
        #expect(subscription.nameMin == 2)
        #expect(subscription.nameMax == 30)
        #expect(subscription.descriptionMax == 45)
        #expect((AppleConstants.localizationLimits[.iap] ?? nil)?.nameMax == 30)
        #expect(AppleConstants.localizationLimits.keys.contains(.group))
        #expect((AppleConstants.localizationLimits[.group] ?? nil) == nil)
        #expect(AppleConstants.newVersionCopiesLocalizations == false)
    }
}
