import SwiftUI
import Domain
import Executor

/// Creates a subscription group, subscriptions and non-consumables in the workspace app. Prices and offers are set by
/// plans afterwards. A product id is burned forever once it is created, so the sheet shows exactly what will be sent
/// and asks for an explicit acknowledgement before Touch ID.
struct CreateProductsSheet: View {
    let session: WorkspaceSession
    @Environment(\.dismiss) private var dismiss

    @State private var groupName = ""
    @State private var subscriptions: [SubscriptionRow] = []
    @State private var nonConsumables: [ProductRow] = []
    @State private var preview: [ProductCreationStep]?
    @State private var reports: [ProductCreationReport] = []
    @State private var acknowledged = false
    @State private var isWorking = false
    @State private var message: String?

    struct SubscriptionRow: Identifiable {
        let id = UUID()
        var productId = ""
        var name = ""
        var period: SubscriptionPeriod = .oneYear
    }

    struct ProductRow: Identifiable {
        let id = UUID()
        var productId = ""
        var name = ""
    }

    private var request: ProductCreationRequest {
        ProductCreationRequest(
            groupName: groupName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : groupName.trimmingCharacters(in: .whitespaces),
            subscriptions: subscriptions.map { NewSubscriptionProduct(productId: $0.productId, name: $0.name.isEmpty ? $0.productId : $0.name, period: $0.period) },
            nonConsumables: nonConsumables.map { NewNonConsumableProduct(productId: $0.productId, name: $0.name.isEmpty ? $0.productId : $0.name) })
    }

    private var problems: [String] { ProductCreationPlanner.problems(request) }

    private var hasInput: Bool { !subscriptions.isEmpty || !nonConsumables.isEmpty }
    private var canCreate: Bool { !isWorking && problems.isEmpty && acknowledged && !(preview?.isEmpty ?? true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspaceBanner(config: session.config)
            Text("New products").font(PurserFont.title2).padding(PurserSpacing.space5)
            PlanFormScaffold {
                PlanFormStep(1, "Subscription group", hint: "The name of an existing group, or of a new one that will be created.") {
                    TextField("Group name", text: $groupName).labelsHidden().textFieldStyle(.roundedBorder)
                }
                PlanFormStep(2, "Subscriptions") {
                    ForEach($subscriptions) { $row in
                        HStack(spacing: PurserSpacing.space2) {
                            TextField("Product ID", text: $row.productId).font(PurserFont.figure)
                            TextField("Name", text: $row.name, prompt: Text("Name (empty = Product ID)"))
                            Picker("Duration", selection: $row.period) {
                                ForEach(SubscriptionPeriod.allCases, id: \.self) { Text(Formatting.period($0)).tag($0) }
                            }
                            .frame(width: 120)
                            removeButton("Remove subscription") { subscriptions.removeAll { $0.id == row.id } }
                        }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    }
                    Button("Add subscription") { subscriptions.append(SubscriptionRow()) }.purserButton()
                }
                PlanFormStep(3, "One-time purchases", hint: "Non-consumable purchases. Prices and offers are set later by a plan.") {
                    ForEach($nonConsumables) { $row in
                        HStack(spacing: PurserSpacing.space2) {
                            TextField("Product ID", text: $row.productId).font(PurserFont.figure)
                            TextField("Name", text: $row.name, prompt: Text("Name (empty = Product ID)"))
                            removeButton("Remove purchase") { nonConsumables.removeAll { $0.id == row.id } }
                        }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    }
                    Button("Add purchase") { nonConsumables.append(ProductRow()) }.purserButton()
                }
                if !problems.isEmpty && (preview != nil || hasInput) {
                    VStack(alignment: .leading, spacing: PurserSpacing.space1) {
                        ForEach(problems, id: \.self) { PlanFormMessage($0, kind: .danger) }
                    }
                }
                if let preview {
                    PlanFormStep(preview.isEmpty ? "Everything is already in App Store Connect" : "\(preview.count) requests will be sent") {
                        if !preview.isEmpty {
                            PlanFormList {
                                ForEach(Array(preview.enumerated()), id: \.offset) { _, step in Text(Self.describe(step)) }
                                Divider().overlay(PurserColor.separator)
                                Toggle("I understand that a Product ID can never be used again once created, not even after the product is deleted.", isOn: $acknowledged)
                            }
                        }
                    }
                }
                if !reports.isEmpty {
                    PlanFormStep("Result") {
                        PlanFormList {
                            ForEach(Array(reports.enumerated()), id: \.offset) { _, report in
                                HStack(alignment: .firstTextBaseline, spacing: PurserSpacing.space2) {
                                    Text(Self.describe(report.step))
                                    Spacer()
                                    Text(Self.detail(report.outcome)).font(PurserFont.callout).foregroundStyle(PurserColor.textSecondary)
                                    Self.badge(report.outcome)
                                }
                            }
                        }
                    }
                }
                if let message { PlanFormMessage(message, kind: .neutral) }
            } footer: {
                HStack(spacing: PurserSpacing.space2) {
                    Button("Fill in the Purser Spike test group") { fill(.purserSpike) }
                        .purserPlainButton()
                        .disabled(isWorking)
                    Spacer()
                    if isWorking { ProgressView().controlSize(.small) }
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .purserButton()
                    // One primary at a time: first the read-only check, then the write it prepared.
                    if preview?.isEmpty ?? true {
                        Button("Check") { Task { await check() } }
                            .keyboardShortcut(.defaultAction)
                            .purserButton(primary: true)
                            .disabled(isWorking || !problems.isEmpty || !hasInput)
                    } else {
                        Button("Check again") { Task { await check() } }
                            .purserButton()
                            .disabled(isWorking || !problems.isEmpty)
                        Button("Create with Touch ID") { Task { await create() } }
                            .purserButton(primary: true)
                            .disabled(!canCreate)
                    }
                }
            }
        }
        .frame(minWidth: 820, minHeight: 620)
        .onChange(of: request) { _, _ in
            preview = nil
            acknowledged = false
        }
    }

    private func removeButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless)
            .accessibilityLabel(label)
            .help(label)
    }

    private func fill(_ preset: ProductCreationRequest) {
        groupName = preset.groupName ?? ""
        subscriptions = preset.subscriptions.map { SubscriptionRow(productId: $0.productId, name: $0.name, period: $0.period) }
        nonConsumables = preset.nonConsumables.map { ProductRow(productId: $0.productId, name: $0.name) }
        reports = []
        message = nil
    }

    /// Reads what the app has now and shows the writes that are still needed. Sends nothing but GETs.
    private func check() async {
        isWorking = true
        defer { isWorking = false }
        message = nil
        reports = []
        do {
            let existing = try await session.makeProductCreator().existing()
            preview = ProductCreationPlanner.steps(request, existing: existing)
        } catch {
            message = "The check failed: \(error.localizedDescription)"
        }
    }

    private func create() async {
        isWorking = true
        defer { isWorking = false }
        message = nil
        do {
            reports = try await session.makeProductCreator().create(request)
            preview = nil
            acknowledged = false
            message = reports.isEmpty ? "There was nothing to create." : "Done. A sync is starting so that the new products appear in the Catalog."
            await session.syncNow()
        } catch {
            message = "Creation failed: \(error.localizedDescription)"
        }
    }

    static func describe(_ step: ProductCreationStep) -> String {
        switch step {
        case let .group(name): return "Group “\(name)”"
        case let .subscription(subscription): return "Subscription \(subscription.productId) (\(Formatting.period(subscription.period)))"
        case let .subscriptionAvailability(productId): return "Availability of \(productId) in all territories"
        case let .nonConsumable(product): return "One-time purchase \(product.productId)"
        case let .nonConsumableAvailability(productId): return "Availability of \(productId) in all territories"
        }
    }

    /// The ASC id or the reason, next to the outcome badge.
    static func detail(_ outcome: ProductCreationOutcome) -> String {
        switch outcome {
        case let .created(ascId): return ascId
        case let .failed(reason), let .skipped(reason): return reason
        }
    }

    static func badge(_ outcome: ProductCreationOutcome) -> PurserBadge {
        switch outcome {
        case .created: return PurserBadge(text: "Created", kind: .success)
        case .failed: return PurserBadge(text: "Failed", kind: .danger)
        case .skipped: return PurserBadge(text: "Skipped", kind: .warning)
        }
    }
}
