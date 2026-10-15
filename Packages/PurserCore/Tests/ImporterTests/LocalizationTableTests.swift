import Foundation
import Testing
import Importer

@Suite struct LocalizationTableTests {
    @Test func headerInAnyOrderAndEmptyCellsKeepTheText() throws {
        let rows = try LocalizationTable.parse([
            [],
            ["Locale", " PRODUCT ", "name", "custom_app_name", "description"],
            ["en-US", "com.example.s", " Fruit Yearly ", "", ""],
            ["", "", "", "", ""],
            ["cs", "group:Synthetic group", "", "Ovoce", ""],
        ])
        #expect(rows == [
            LocalizationTableRow(rowNumber: 3, product: "com.example.s", locale: "en-US", name: "Fruit Yearly"),
            LocalizationTableRow(rowNumber: 5, product: "group:Synthetic group", locale: "cs", customAppName: "Ovoce"),
        ])
    }

    @Test func aMissingOrUnknownColumnOrValueIsNamed() {
        #expect(throws: LocalizationTableError.empty) { try LocalizationTable.parse([[""]]) }
        #expect(throws: LocalizationTableError.missingColumn("locale")) { try LocalizationTable.parse([["product", "name"]]) }
        #expect(throws: LocalizationTableError.unknownColumn("desc")) { try LocalizationTable.parse([["product", "locale", "desc"]]) }
        #expect(throws: LocalizationTableError.duplicateColumn("name")) { try LocalizationTable.parse([["product", "locale", "name", "Name"]]) }
        #expect(throws: LocalizationTableError.missingValue(row: 2, column: "locale")) {
            try LocalizationTable.parse([["product", "locale", "name"], ["com.example.s", "", "Fruit"]])
        }
        #expect(LocalizationTableError.missingValue(row: 2, column: "locale").description == "Row 2 has no locale.")
    }

    @Test func csvQuotesWhatNeedsQuotingAndReadsBack() async throws {
        let rows = [
            LocalizationTableRow(product: "com.example.s", locale: "en-US", name: "Fruit, \"fresh\"", description: "Line one\nline two"),
            LocalizationTableRow(product: "group:Synthetic group", locale: "cs", name: "Ovoce", customAppName: "O"),
        ]
        let text = LocalizationTable.csv(rows)
        #expect(text.hasPrefix("product,locale,name,description,custom_app_name\r\n"))
        #expect(text.contains("\"Fruit, \"\"fresh\"\"\""))
        let back = try LocalizationTable.parse(try await CSVTableSource(data: Data(text.utf8)).fetchRows())
        #expect(back.map(\.name) == ["Fruit, \"fresh\"", "Ovoce"])
        #expect(back.first?.description == "Line one\nline two")
        #expect(back.last?.customAppName == "O")
    }

    @Test func aTextThatStartsLikeAFormulaIsExportedAsTextAndImportedBackUnchanged() async throws {
        let rows = [
            LocalizationTableRow(product: "com.example.s", locale: "en-US", name: "=SUM(1)", description: "+1, free"),
            LocalizationTableRow(product: "com.example.s", locale: "cs", name: "-5 off", description: "@home", customAppName: "\tTabbed"),
            LocalizationTableRow(product: "group:Synthetic group", locale: "cs", name: "'Hello", customAppName: "'=still text"),
            LocalizationTableRow(product: "group:Synthetic group", locale: "de-DE", name: "''-x", customAppName: "Plain"),
        ]
        let text = LocalizationTable.csv(rows)
        let lines = text.components(separatedBy: "\r\n")
        #expect(lines[1] == "com.example.s,en-US,'=SUM(1),\"'+1, free\",")
        #expect(lines[2] == "com.example.s,cs,'-5 off,'@home,'\tTabbed")
        #expect(lines[3] == "group:Synthetic group,cs,'Hello,,''=still text")
        #expect(lines[4] == "group:Synthetic group,de-DE,'''-x,,Plain")
        let back = try LocalizationTable.parse(try await CSVTableSource(data: Data(text.utf8)).fetchRows())
        #expect(back.map(\.name) == ["=SUM(1)", "-5 off", "'Hello", "''-x"])
        #expect(back.map(\.description) == ["+1, free", "@home", nil, nil])
        #expect(back.map(\.customAppName) == [nil, "\tTabbed", "'=still text", "Plain"])
    }

    @Test func aLeadingCarriageReturnIsGuardedToo() throws {
        let text = LocalizationTable.csv([LocalizationTableRow(product: "com.example.s", locale: "en-US", name: "\r=1")])
        #expect(text.contains("\"'\r=1\""))
        #expect(try LocalizationTable.parse([["product", "locale", "name"], ["com.example.s", "en-US", "'\r=1"]]).first?.name == "\r=1")
    }

    @Test func onlyAnApostropheInFrontOfAFormulaCharacterIsStripped() throws {
        let rows = try LocalizationTable.parse([
            ["product", "locale", "name", "description"],
            ["com.example.s", "en-US", "'=SUM(1)", "'Hello"],
            ["com.example.s", "cs", "'", "''"],
            ["com.example.s", "de-DE", "Rock 'n' roll", "'12"],
        ])
        #expect(rows.map(\.name) == ["=SUM(1)", "'", "Rock 'n' roll"])
        #expect(rows.map(\.description) == ["'Hello", "''", "'12"])
    }

    @Test func anExportWithoutItemsStillImportsBackToNothing() async throws {
        let text = LocalizationTable.csv([])
        #expect(text == "product,locale,name,description,custom_app_name\r\n")
        #expect(try LocalizationTable.parse(try await CSVTableSource(data: Data(text.utf8)).fetchRows()).isEmpty)
    }
}
