import SwiftUI
import Domain
import Store

/// Workspace settings: the import mapping as JSON (ImportMapping). "Apply" validates the JSON, bumps the version
/// when the content changed and writes it into `config`; the settings screen saves and audits it.
struct ImportMappingEditor: View {
    @Binding var config: WorkspaceConfig
    @State private var text = ""
    @State private var message: String?

    var body: some View {
        PurserSettingsPanel("Import mapping", hint: "The columns of the import sheet described as JSON. The CSV template from New plan sets it by itself.") {
            TextEditor(text: $text)
                .font(PurserFont.identifier)
                .frame(minHeight: 180)
                .scrollContentBackground(.hidden)
                .padding(PurserSpacing.space1)
                .background(PurserColor.glassFill, in: RoundedRectangle(cornerRadius: PurserRadius.radiusSm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: PurserRadius.radiusSm, style: .continuous).strokeBorder(PurserColor.borderControl))
            HStack(spacing: PurserSpacing.space2) {
                Button("Apply") { apply() }.purserButton()
                Button("Paste example") { text = Self.example }.purserPlainButton()
                Spacer()
                if let message { Text(message).font(PurserFont.callout).foregroundStyle(PurserColor.textSecondary) }
            }
        }
        .onAppear { text = config.importMapping.flatMap { try? Self.pretty($0) } ?? "" }
    }

    private func apply() {
        do {
            var mapping = try JSONCoding.decode(ImportMapping.self, from: text)
            if let old = config.importMapping, old != mapping, mapping.version <= old.version { mapping.version = old.version + 1 }
            config.importMapping = mapping
            text = try Self.pretty(mapping)
            message = "Mapping v\(mapping.version) is ready. The Save changes button saves it."
        } catch {
            message = "Invalid mapping: \(error.localizedDescription)"
        }
    }

    static func pretty(_ mapping: ImportMapping) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(mapping), as: UTF8.self)
    }

    static let example = """
    {
      "version": 1,
      "source": { "csv": {} },
      "firstDataRow": 2,
      "countryColumn": "A",
      "currencyColumn": "B",
      "targets": [
        { "column": "C", "productAscId": "6400000001", "kind": { "regularPrice": { "planType": "UPFRONT" } }, "writes": false },
        { "column": "D", "productAscId": "6400000001", "kind": { "introPayUpFront": { "duration": "ONE_YEAR" } }, "nominalDiscount": 0.2, "writes": true }
      ]
    }
    """
}
