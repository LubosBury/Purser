import Foundation
import Testing
import Domain
import Store

@Suite struct JSONCodingTests {
    @Test func encodesWithSortedKeysAndISODates() throws {
        struct Sample: Codable { var zeta: Int; var alpha: Date }
        let text = try JSONCoding.string(Sample(zeta: 1, alpha: Date(timeIntervalSince1970: 1_791_547_200)))
        #expect(text == "{\"alpha\":\"2026-10-09T12:00:00Z\",\"zeta\":1}")
        let back = try JSONCoding.decode(Sample.self, from: text)
        #expect(back.alpha == Date(timeIntervalSince1970: 1_791_547_200))
    }

    @Test func timestampsAreUTCWithMilliseconds() throws {
        let date = Date(timeIntervalSince1970: 1_791_547_200.25)
        let text = Timestamp.string(date)
        #expect(text == "2026-10-09T12:00:00.250Z")
        #expect(try Timestamp.date(text) == date)
    }
}
