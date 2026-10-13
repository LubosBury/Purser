import SwiftUI
import Audit

/// Audit events, chain verification and JSONL export (spec §8 Historie). Plans by state arrive with M1/M2.
struct HistoryView: View {
    let session: WorkspaceSession
    @State private var rows: [AuditRow] = []
    @State private var tab: Tab = .plans
    @State private var verification: Verification?
    @State private var exportDocument: JSONLDocument?
    @State private var exporting = false
    @State private var exportedCount = 0

    enum Tab: Hashable { case plans, audit }

    enum Verification {
        case ok(Int), broken(Int64), failed(String)
    }

    struct AuditRow: Identifiable {
        let event: AuditEvent
        var id: Int64 { event.seq }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PurserSpacing.space4) {
            PurserScreenHeader("History") {
                Picker("Record type", selection: $tab) {
                    Text("Plans").tag(Tab.plans)
                    Text("Audit").tag(Tab.audit)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                verificationBadge
                Button(verification == nil ? "Verify chain" : "Verify again", action: verify).purserButton()
                Button("Export JSONL…", action: prepareExport).purserButton()
            }
            switch tab {
            case .plans:
                PlanHistorySection(session: session)
            case .audit:
                Table(rows) {
                    TableColumn("#") { row in PurserFigure("\(row.event.seq)") }
                        .width(50)
                    TableColumn("Time (UTC)") { row in Text(row.event.ts.formatted(.iso8601)).font(PurserFont.figure) }
                        .width(180)
                    TableColumn("Type") { row in Text(row.event.type.rawValue) }
                        .width(150)
                    TableColumn("References") { row in
                        Text(row.event.refs.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
                            .font(PurserFont.identifier)
                            .foregroundStyle(PurserColor.textSecondary)
                    }
                    TableColumn("Payload") { row in
                        Text(row.event.payloadJSON).lineLimit(2).font(PurserFont.identifier).help(row.event.payloadJSON)
                    }
                }
                .purserTable()
            }
            AuditFingerprintLine(session: session)
        }
        .padding(PurserSpacing.space5)
        .onAppear(perform: load)
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: JSONLDocument.contentType,
                      defaultFilename: "purser-audit.jsonl") { result in
            switch result {
            case let .success(url):
                let head = try? session.audit.head()
                do {
                    try session.audit.append(.exportPerformed, refs: [:],
                                             payload: ExportPayload(fileName: url.lastPathComponent, events: exportedCount,
                                                                    headSeq: head?.seq, headHash: head?.hash))
                } catch {
                    session.errorMessage = "The export was not recorded in the audit: \(error)"
                }
                load()
            case let .failure(error):
                session.errorMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    private func load() {
        do {
            let headSeq = try session.audit.head()?.seq ?? 0
            rows = try session.audit.events(after: max(0, headSeq - 500), limit: 500).reversed().map(AuditRow.init)
        } catch {
            session.errorMessage = "The audit cannot be loaded: \(error)"
        }
    }

    /// The chain state as a word and an icon; a broken chain is never signalled by colour alone.
    @ViewBuilder
    private var verificationBadge: some View {
        switch verification {
        case nil: EmptyView()
        case let .ok(count): PurserBadge(text: "Chain verified · \(count) events", kind: .success)
        case let .broken(seq): PurserBadge(text: "Chain broken at event #\(seq)", kind: .danger)
        case let .failed(message): PurserBadge(text: "Verification failed", kind: .danger).help(message)
        }
    }

    private func verify() {
        do {
            switch try session.audit.verifyChain() {
            case let .ok(count): verification = .ok(count)
            case let .broken(seq): verification = .broken(seq)
            }
        } catch {
            verification = .failed("\(error)")
        }
    }

    private func prepareExport() {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("purser-audit-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            exportedCount = try session.audit.exportJSONL(to: temporary)
            exportDocument = JSONLDocument(data: try Data(contentsOf: temporary))
            exporting = true
        } catch {
            session.errorMessage = "The export cannot be prepared: \(error)"
        }
    }
}
