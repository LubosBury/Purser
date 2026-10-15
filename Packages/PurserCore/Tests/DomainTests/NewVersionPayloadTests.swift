import Foundation
import Testing
import Domain

@Suite struct NewVersionPayloadTests {
    @Test func createMetadataVersionIsAPostWithAVersionNaturalKey() {
        #expect(WritePayload.createMetadataVersion(owner: .group("7000000001")).op == .post)
        #expect(NaturalKey.of(.createMetadataVersion(owner: .subscription("6500000001"))) == "V+|S|6500000001")
        #expect(NaturalKey.of(.createMetadataVersion(owner: .iap("6600000001"))) == "V+|I|6600000001")
        #expect(NaturalKey.of(.createMetadataVersion(owner: .group("7000000001"))) == "V+|G|7000000001")
    }

    @Test func aVersionItemSurvivesEncoding() throws {
        let owner = LocalizationOwner.subscription("6500000001")
        let item = PlannedItem(seq: 1, cell: .metadataVersion(owner: owner), payload: .createMetadataVersion(owner: owner),
                               before: .metadataVersion(nil),
                               target: .metadataVersion(MetadataVersion(ascId: "", owner: owner, number: 3, state: .prepareForSubmission)),
                               rules: ["N5"])
        let decoded = try JSONDecoder().decode(PlannedItem.self, from: try JSONEncoder().encode(item))
        #expect(decoded == item)
        #expect(decoded.naturalKey == "V+|S|6500000001")
    }
}
