import SwiftUI
import Domain
import Store
import Audit

/// History screen (spec §8): every plan with its state as a badge; a row opens the plan on the Plans screen.
struct PlanHistorySection: View {
    let session: WorkspaceSession
    @State private var rows: [PlanRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: PurserSpacing.space2) {
            if rows.isEmpty {
                ContentUnavailableView("No plans yet", systemImage: "clock.arrow.circlepath")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // A click switches to the Plans screen at once; it shows its own placeholder until the rows are ready.
                Table(rows, selection: Binding<String?>(get: { nil }, set: { id in
                    guard let id else { return }
                    session.showPlan(id: id)
                })) {
                    TableColumn("Created") { row in
                        Text(Formatting.timestamp(row.plan.createdAt)).font(PurserFont.figure)
                    }
                    .width(140)
                    TableColumn("Plan") { row in Text(PlanFormatting.originLabel(row.plan.origin)) }
                        .width(min: 120, ideal: 150)
                    TableColumn("State") { row in PlanFormatting.stateBadge(row.plan) }
                        .width(180)
                    TableColumn("Reason") { row in Text(row.plan.reason ?? "—").foregroundStyle(PurserColor.textSecondary) }
                    TableColumn("Ended") { row in
                        Text(row.plan.endReason?.rawValue ?? "—").font(PurserFont.identifier).foregroundStyle(PurserColor.textSecondary)
                    }
                    .width(min: 100, ideal: 130)
                    TableColumn("ID") { row in
                        Text(row.plan.id).font(PurserFont.identifier).foregroundStyle(PurserColor.textSecondary).textSelection(.enabled)
                    }
                }
                .purserTable()
            }
        }
        .onAppear(perform: load)
        .onChange(of: session.applyRevision) { _, _ in load() }
    }

    private func load() {
        let plans = (try? session.planStore.plans(states: nil)) ?? []
        rows = plans.sorted { $0.createdAt > $1.createdAt }.map(PlanRow.init)
    }
}

/// The last published audit fingerprint, as one quiet line under the History tables.
struct AuditFingerprintLine: View {
    let session: WorkspaceSession
    @State private var fingerprint: String?

    var body: some View {
        Text(fingerprint ?? "Last fingerprint: not published yet")
            .font(PurserFont.identifier)
            .foregroundStyle(PurserColor.textTertiary)
            .textSelection(.enabled)
            .onAppear { fingerprint = lastFingerprint() }
            .onChange(of: session.applyRevision) { _, _ in fingerprint = lastFingerprint() }
    }

    private func lastFingerprint() -> String? {
        guard let head = try? session.audit.head() else { return nil }
        let events = (try? session.audit.events(after: max(0, head.seq - 5_000), limit: 5_000)) ?? []
        guard let event = events.last(where: { $0.type == .chainHeadPublished }),
              let object = (try? JSONSerialization.jsonObject(with: Data(event.payloadJSON.utf8))) as? [String: Any] else { return nil }
        let seq = (object["seq"] as? Int).map(String.init) ?? "?"
        let hash = object["hash"] as? String ?? "?"
        return "Last fingerprint: seq \(seq), hash \(hash), \(event.ts.formatted(.iso8601))"
    }
}
