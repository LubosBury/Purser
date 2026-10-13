import Foundation
import Testing
import Importer

@Suite struct CSVTableSourceTests {
    private func rows(_ text: String) async throws -> [[String]] {
        try await CSVTableSource(data: Data(text.utf8)).fetchRows()
    }

    @Test func plainRows() async throws {
        #expect(try await rows("a,b,c\n1,2,3\n") == [["a", "b", "c"], ["1", "2", "3"]])
    }

    @Test func quotedFieldWithComma() async throws {
        #expect(try await rows("\"Korea, Republic of\",KRW\n") == [["Korea, Republic of", "KRW"]])
    }

    @Test func escapedQuotes() async throws {
        #expect(try await rows("\"say \"\"hi\"\"\",x") == [["say \"hi\"", "x"]])
    }

    @Test func crlfAndCrLineEnds() async throws {
        #expect(try await rows("a,b\r\nc,d\r\n") == [["a", "b"], ["c", "d"]])
        #expect(try await rows("a,b\rc,d") == [["a", "b"], ["c", "d"]])
    }

    @Test func byteOrderMarkIsDropped() async throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("Country,Currency\nCzech Republic,CZK\n".utf8)
        #expect(try await CSVTableSource(data: data).fetchRows() == [["Country", "Currency"], ["Czech Republic", "CZK"]])
    }

    @Test func lineBreakInsideQuotes() async throws {
        #expect(try await rows("\"line1\r\nline2\",x\n") == [["line1\r\nline2", "x"]])
    }

    @Test func emptyFieldsAndMissingTrailingNewline() async throws {
        #expect(try await rows("a,,\n,b") == [["a", "", ""], ["", "b"]])
        #expect(try await rows("\"\"") == [[""]])
    }

    @Test func typographicApostropheSurvives() async throws {
        #expect(try await rows("Côte d’Ivoire,XOF\n") == [["Côte d’Ivoire", "XOF"]])
    }

    @Test func unterminatedQuoteThrows() async throws {
        await #expect(throws: CSVError.unterminatedQuote(line: 2)) { try await rows("a,b\n\"open,c\nd\n") }
    }

    @Test func invalidUTF8Throws() async throws {
        await #expect(throws: CSVError.notUTF8) { try await CSVTableSource(data: Data([0xFF, 0xFE, 0xFF])).fetchRows() }
    }
}

@Suite struct ImportColumnsTests {
    @Test func lettersToIndex() {
        #expect(ImportColumns.index(of: "A") == 0)
        #expect(ImportColumns.index(of: "Z") == 25)
        #expect(ImportColumns.index(of: "AA") == 26)
        #expect(ImportColumns.index(of: "AZ") == 51)
        #expect(ImportColumns.index(of: "BA") == 52)
        #expect(ImportColumns.index(of: "g") == 6)
        #expect(ImportColumns.index(of: "") == nil)
        #expect(ImportColumns.index(of: "A1") == nil)
        #expect(ImportColumns.index(of: "ABCD") == nil)
    }

    @Test func lettersRoundTrip() {
        for i in 0..<1000 { #expect(ImportColumns.index(of: ImportColumns.letters(for: i)) == i) }
    }
}
