import SwiftUI
import Domain
import Catalog

struct OfferCodeRegistryView: View {
    let entries: [OfferCodeRegistryEntry]
    let subscriptions: [String: SubscriptionInfo]
    @State private var filter = ""

    private var visible: [OfferCodeRegistryEntry] {
        filter.isEmpty ? entries : entries.filter { $0.offerCode.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PurserSpacing.space2) {
            Text("Code registry (O1)").font(PurserFont.headline)
            PlanFormHint("Every code Purser has ever seen in App Store Connect, including those of deleted offers. None of them can be used again.")
            TextField("Search code", text: $filter).textFieldStyle(.roundedBorder)
            Table(visible) {
                TableColumn("Code") { entry in Text(entry.offerCode).font(PurserFont.identifier) }
                TableColumn("Product") { entry in Text(subscriptions[entry.productAscId]?.productId ?? entry.productAscId) }
                TableColumn("First seen in snapshot") { entry in PurserFigure("#\(entry.firstSeenSync)") }
            }
            .purserTable()
        }
        .padding(PurserSpacing.space5)
    }
}
