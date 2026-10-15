import Testing
import Domain
import Policy

@Suite struct RequestEstimatorLocalizationTests {
    @Test func aTextWithoutIdsCostsOneMoreRead() {
        let owner = LocalizationOwner.subscription("s")
        func item(_ seq: Int, _ locale: String, localizationId: String?) -> PlannedItem {
            PlannedItem(seq: seq, cell: .localization(owner: owner, locale: locale),
                        payload: .setLocalization(SetLocalization(owner: owner, locale: locale, text: LocalizationText(name: "X"),
                                                                  localizationId: localizationId, versionId: nil)),
                        before: .localization(live: nil, pending: nil, pendingVersion: nil),
                        target: .localization(live: nil, pending: nil, pendingVersion: nil))
        }
        // 2 writes + 1 app read + 1 product + 2 × 1 page (one scope "s|T") + 1 read for the text without ids.
        #expect(RequestEstimator.requests(items: [item(1, "en-US", localizationId: "loc-1"), item(2, "cs", localizationId: nil)]) == 7)
        #expect(RequestEstimator.requests(items: [item(1, "en-US", localizationId: "loc-1")]) == 5)
    }
}
