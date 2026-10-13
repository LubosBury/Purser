import SwiftUI
import Catalog
import Domain

/// Every stored version of the selected cells (observation version ranges, provenance, expired).
struct CellHistoryView: View {
    let session: WorkspaceSession
    let cells: [CellKey]

    var body: some View {
        List {
            if cells.isEmpty {
                Text("Select a table row.")
                    .foregroundStyle(.secondary)
            }
            ForEach(cells, id: \.self) { cell in
                Section(cell.storageKey) {
                    let records = session.history(for: cell)
                    if records.isEmpty {
                        Text("No records").foregroundStyle(.secondary)
                    }
                    ForEach(records, id: \.id) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(record.provenance.rawValue).bold()
                                Text("sync \(record.firstSync)–\(record.lastSync)")
                                if record.expired { Text("expired").foregroundStyle(.secondary) }
                            }
                            Text(record.rawJSON)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    CellPlanItemsList(session: session, cell: cell)
                }
            }
        }
    }
}
