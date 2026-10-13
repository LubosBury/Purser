import Foundation
import Testing
import Domain

@Suite struct CalendarDateTests {
    @Test func parsesValidISODate() throws {
        let date = try #require(CalendarDate(iso: "2026-02-28"))
        #expect(date.year == 2026)
        #expect(date.month == 2)
        #expect(date.day == 28)
        #expect(date.iso == "2026-02-28")
        #expect(date.description == "2026-02-28")
    }

    @Test(arguments: ["2026-02-30", "2026-13-01", "2026-1-01", "26-01-01", "2026/01/01", "2026-01-01T00:00:00Z", "", "abcd-ef-gh", "2026-00-10"])
    func rejectsInvalidISODate(_ text: String) {
        #expect(CalendarDate(iso: text) == nil)
    }

    @Test func acceptsLeapDay() {
        #expect(CalendarDate(iso: "2028-02-29") != nil)
        #expect(CalendarDate(iso: "2027-02-29") == nil)
    }

    @Test func todayIsComputedInUTC() {
        // 2026-10-09T23:30:00Z is already 2026-10-10 in Prague, but Purser's "today" is UTC.
        let late = Date(timeIntervalSince1970: 1_791_588_600)
        #expect(CalendarDate.today(now: late) == CalendarDate(year: 2026, month: 10, day: 9))
        // 2026-10-10T00:30:00Z is still 2026-10-09 in New York, but UTC says the 10th.
        let early = Date(timeIntervalSince1970: 1_791_592_200)
        #expect(CalendarDate.today(now: early) == CalendarDate(year: 2026, month: 10, day: 10))
    }

    @Test func startOfDayIsMidnightUTC() {
        let date = CalendarDate(year: 2026, month: 10, day: 9)
        #expect(date.startOfDayUTC == Date(timeIntervalSince1970: 1_791_504_000))
    }

    @Test func addingDaysCrossesMonthAndYear() {
        let date = CalendarDate(year: 2026, month: 12, day: 30)
        #expect(date.adding(days: 1) == CalendarDate(year: 2026, month: 12, day: 31))
        #expect(date.adding(days: 2) == CalendarDate(year: 2027, month: 1, day: 1))
        #expect(CalendarDate(year: 2027, month: 3, day: 1).adding(days: -1) == CalendarDate(year: 2027, month: 2, day: 28))
        #expect(CalendarDate(year: 2028, month: 3, day: 1).adding(days: -1) == CalendarDate(year: 2028, month: 2, day: 29))
        #expect(CalendarDate(year: 2026, month: 10, day: 9).adding(days: 0) == CalendarDate(year: 2026, month: 10, day: 9))
    }

    @Test func ordersChronologically() {
        let a = CalendarDate(year: 2026, month: 1, day: 31)
        let b = CalendarDate(year: 2026, month: 2, day: 1)
        let c = CalendarDate(year: 2027, month: 1, day: 1)
        #expect(a < b)
        #expect(b < c)
        #expect([c, a, b].sorted() == [a, b, c])
    }

    @Test func codableUsesISOString() throws {
        let data = try JSONEncoder().encode([CalendarDate(year: 2026, month: 3, day: 7)])
        #expect(String(decoding: data, as: UTF8.self) == "[\"2026-03-07\"]")
        let back = try JSONDecoder().decode([CalendarDate].self, from: data)
        #expect(back == [CalendarDate(year: 2026, month: 3, day: 7)])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([CalendarDate].self, from: Data("[\"2026-02-30\"]".utf8))
        }
    }
}
