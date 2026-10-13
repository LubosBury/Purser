import SwiftUI
import Domain
import Store

/// Catalog cell history (spec §8): the plan items that touched the cell, oldest plan first.
struct CellPlanItemsList: View {
    let session: WorkspaceSession
    let cell: CellKey

    var body: some View {
        let rows = lines()
        VStack(alignment: .leading, spacing: 2) {
            Text("Plan items (\(rows.count))").font(.caption.bold())
            ForEach(rows, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
        }
    }

    private func lines() -> [String] {
        let plans = ((try? session.planStore.plans(states: nil)) ?? []).sorted { $0.createdAt < $1.createdAt }
        return plans.flatMap { plan -> [String] in
            ((try? session.planStore.items(planId: plan.id)) ?? []).filter { $0.item.cell == cell }.map { stored in
                var text = "\(plan.id) #\(stored.item.seq) \(stored.item.op.rawValue) \(stored.state.rawValue)"
                if let verified = stored.verifiedAt { text += " · verified \(verified.formatted(.iso8601))" }
                if let effective = stored.effectiveAt { text += " · effective \(effective.formatted(.iso8601))" }
                if !stored.item.flags.isEmpty { text += " · \(stored.item.flags.map(\.rawValue).joined(separator: ","))" }
                return text
            }
        }
    }
}
