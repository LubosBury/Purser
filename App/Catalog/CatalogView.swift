import SwiftUI
import Catalog
import Domain

/// Product list + 175-row territory table + cell history (spec §8 Katalog).
struct CatalogView: View {
    let session: WorkspaceSession
    var onNewPlan: () -> Void
    @State private var productId: String?
    @State private var search = ""
    @State private var rowFilter: RowFilter = .all

    enum RowFilter: Hashable { case all, scheduled, findings }
    @State private var planType: PlanType = .upfront
    @State private var selectedTerritory: TerritoryCode?
    @State private var showHistory = false
    @State private var showCreateProducts = false

    private var today: CalendarDate { CalendarDate.today(now: Date()) }

    var body: some View {
        PurserGlassContainer {
            VStack(alignment: .leading, spacing: PurserSpacing.space4) {
                header
                HStack(alignment: .top, spacing: PurserSpacing.space4) {
                    productList
                        .frame(minWidth: 200, idealWidth: 260, maxWidth: 260)
                        .purserGlassPanel(padding: PurserSpacing.space2)
                    table
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(PurserSpacing.space5)
        }
        // A sheet, not `.inspector`: an inspector reserves its column in the split view's minimum width even while
        // hidden, which pushed the whole window content wider than the window.
        .sheet(isPresented: $showHistory) { historySheet }
        .onChange(of: selectedTerritory) { _, territory in
            if territory == nil { showHistory = false }
        }
    }

    private var historySheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Cell history · \(selectedTerritory?.rawValue ?? "")").font(PurserFont.title2)
                Spacer()
                Button("Close") { showHistory = false }
                    .keyboardShortcut(.cancelAction)
                    .purserButton()
            }
            .padding(PurserSpacing.space5)
            CellHistoryView(session: session, cells: selectedCells)
        }
        .frame(width: 560, height: 560)
    }

    // MARK: Header

    private var header: some View {
        PurserScreenHeader("Catalog") {
            Spacer()
            TextField("Search territory or currency", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 140, idealWidth: 240, maxWidth: 240)
            Button("New products…") { showCreateProducts = true }
                .purserButton()
                .disabled(session.isSyncing || session.syncBlockedReason != nil)
                .sheet(isPresented: $showCreateProducts) { CreateProductsSheet(session: session) }
            Button("New plan", action: onNewPlan)
                .purserButton(primary: true)
                .disabled(session.snapshot == nil)
        }
    }

    // MARK: Products

    private var subscriptions: [SubscriptionInfo] {
        (session.snapshot?.subscriptions.values.map { $0 } ?? []).sorted { ($0.groupName, $0.name) < ($1.groupName, $1.name) }
    }

    private var iaps: [IAPInfo] {
        (session.snapshot?.iaps.values.map { $0 } ?? []).sorted { $0.name < $1.name }
    }

    private var productList: some View {
        List(selection: $productId) {
            Section("Subscriptions") {
                ForEach(subscriptions, id: \.ascId) { subscription in
                    productRow(name: subscription.name, detail: "\(Formatting.period(subscription.period)) · \(Formatting.productState(subscription.state))")
                        .tag(subscription.ascId)
                }
            }
            Section("One-time purchases") {
                ForEach(iaps, id: \.ascId) { iap in
                    productRow(name: iap.name, detail: "\(Formatting.iapType(iap.iapType)) · \(Formatting.productState(iap.state))")
                        .tag(iap.ascId)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    private func productRow(name: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: PurserSpacing.space1 / 2) {
            Text(name).font(PurserFont.body)
            Text(detail).font(PurserFont.callout).foregroundStyle(PurserColor.textSecondary)
        }
    }

    /// Product id as the developer typed it; the ASC id stays in the cell history.
    private var selectedProductIdentifier: String? {
        guard let productId, let snapshot = session.snapshot else { return nil }
        return snapshot.subscriptions[productId]?.productId ?? snapshot.iaps[productId]?.productId
    }

    private var selectedProductName: String {
        guard let productId, let snapshot = session.snapshot else { return "" }
        return snapshot.subscriptions[productId]?.name ?? snapshot.iaps[productId]?.name ?? ""
    }

    // MARK: Table

    private var rows: [CatalogTableRow] {
        guard let snapshot = session.snapshot, let productId else { return [] }
        let observations = session.liveObservations(productAscId: productId)
        if snapshot.iaps[productId] != nil {
            return CatalogTable.iapRows(snapshot: snapshot, iapId: productId, today: today, observations: observations, findings: session.findings)
        }
        return CatalogTable.subscriptionRows(snapshot: snapshot, subscriptionId: productId, planType: planType, today: today,
                                             observations: observations, findings: session.findings)
    }

    private var selectedCells: [CellKey] {
        rows.first { $0.territory == selectedTerritory }?.cells ?? []
    }

    private var visibleRows: [CatalogTableRow] {
        let needle = search.trimmingCharacters(in: .whitespaces).uppercased()
        return rows.filter { row in
            switch rowFilter {
            case .all: break
            case .scheduled: if row.scheduledStart == nil { return false }
            case .findings: if row.findingCount == 0 { return false }
            }
            guard !needle.isEmpty else { return true }
            return row.territory.rawValue.uppercased().contains(needle) || (row.currency?.rawValue.uppercased().contains(needle) ?? false)
        }
    }

    private var selectedRow: CatalogTableRow? { rows.first { $0.territory == selectedTerritory } }

    @ViewBuilder
    private var table: some View {
        if productId == nil {
            ContentUnavailableView("Select a product", systemImage: "list.bullet.rectangle")
        } else {
            VStack(alignment: .leading, spacing: PurserSpacing.space3) {
                tableHeader
                Table(visibleRows, selection: $selectedTerritory) {
                    TableColumn("Territory") { row in Text(row.territory.rawValue).font(PurserFont.body) }
                        .width(80)
                    TableColumn("Currency") { row in Text(row.currency?.rawValue ?? "—").foregroundStyle(PurserColor.textSecondary) }
                        .width(50)
                    TableColumn("Current price") { row in PurserFigure(Formatting.price(row.currentPrice, currency: row.currency)) }
                        .width(min: 90, ideal: 110)
                    TableColumn("Scheduled change") { row in
                        PurserFigure(scheduled(row), color: row.scheduledStart == nil ? PurserColor.textSecondary : PurserColor.textPrimary)
                    }
                    .width(min: 130, ideal: 200)
                    TableColumn("Introductory offer") { row in Text(introCell(row)).help(introCell(row)) }
                        .width(min: 130, ideal: 180)
                    TableColumn("Promo") { row in PurserFigure("\(row.promoCount)") }
                        .width(50)
                    TableColumn("State") { row in status(row) }
                }
                .purserTable()
                if let selectedRow { detailStrip(selectedRow) }
            }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: PurserSpacing.space3) {
            Text(selectedProductName).font(PurserFont.headline).lineLimit(1)
            if let identifier = selectedProductIdentifier {
                Text(identifier).font(PurserFont.identifier).foregroundStyle(PurserColor.textSecondary).lineLimit(1).textSelection(.enabled)
            }
            Text("\(rows.count) territories").font(PurserFont.callout).foregroundStyle(PurserColor.textSecondary).lineLimit(1)
            Spacer(minLength: 0)
            if let productId, session.snapshot?.subscriptions[productId]?.monthlyPlanAvailable == true {
                Picker("Payment mode", selection: $planType) {
                    Text("Up front").tag(PlanType.upfront)
                    Text("Monthly").tag(PlanType.monthly)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Picker("Row filter", selection: $rowFilter) {
                Text("All").tag(RowFilter.all)
                Text("With a change \(rows.filter { $0.scheduledStart != nil }.count)").tag(RowFilter.scheduled)
                Text("With a finding \(rows.filter { $0.findingCount > 0 }.count)").tag(RowFilter.findings)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    /// Status is a word in a badge, never colour alone.
    private func status(_ row: CatalogTableRow) -> some View {
        HStack(spacing: PurserSpacing.space1) {
            if row.scheduledStart != nil { PurserBadge(text: "Scheduled", kind: .info) }
            if row.findingCount > 0 { PurserBadge(text: "Findings \(row.findingCount)", kind: .warning) }
            ForEach(row.flags, id: \.self) { PurserBadge(text: $0) }
        }
    }

    private func introCell(_ row: CatalogTableRow) -> String {
        let current = intro(row.currentIntro, currency: row.currency)
        guard row.futureIntro != nil else { return current }
        return "\(current) → \(intro(row.futureIntro, currency: row.currency))"
    }

    private func detailStrip(_ row: CatalogTableRow) -> some View {
        HStack(spacing: PurserSpacing.space4) {
            Text("\(row.territory.rawValue) · \(row.currency?.rawValue ?? "—")").font(PurserFont.headline)
            if row.scheduledStart != nil {
                Text("\(Formatting.price(row.currentPrice, currency: row.currency)) → \(Formatting.price(row.scheduledPrice, currency: row.currency))")
                    .font(PurserFont.figure)
                Text("Effective from \(Formatting.date(row.scheduledStart))\(row.scheduledPreserved == true ? " · existing subscribers keep their price" : "")")
                    .font(PurserFont.callout)
                    .foregroundStyle(PurserColor.textSecondary)
            } else {
                Text(Formatting.price(row.currentPrice, currency: row.currency)).font(PurserFont.figure)
                Text("No scheduled change").font(PurserFont.callout).foregroundStyle(PurserColor.textSecondary)
            }
            if let provenance = row.provenance {
                Text("Source: \(provenance.rawValue)").font(PurserFont.callout).foregroundStyle(PurserColor.textSecondary)
            }
            Spacer()
            Button("Cell history") { showHistory = true }
                .controlSize(.small)
                .purserButton()
        }
        .purserGlassPanel(padding: PurserSpacing.space3)
    }

    private func scheduled(_ row: CatalogTableRow) -> String {
        guard let start = row.scheduledStart else { return "—" }
        return "\(Formatting.price(row.scheduledPrice, currency: row.currency)) from \(start.iso)"
    }

    private func intro(_ summary: IntroSummary?, currency: CurrencyCode?) -> String {
        guard let summary else { return "—" }
        var text = "\(PlanFormatting.modeLabel(summary.mode)) \(PlanFormatting.durationLabel(summary.duration))"
        if summary.numberOfPeriods > 1 { text += " ×\(summary.numberOfPeriods)" }
        if summary.customerPrice != nil {
            text += " \(Formatting.price(summary.customerPrice, currency: currency)) (\(Formatting.percent(summary.shareOfRegular)))"
        }
        if let end = summary.endDate { text += " until \(end.iso)" }
        return text
    }
}
