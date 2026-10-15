import Foundation
import Audit
import Catalog
import Domain
import Executor
import Importer
import MCPBridge
import MCPTools
import Planner
import Store

/// Runs the tools that arrive over the MCP bridge against the open workspace, through the same session, planning
/// model and apply controller the windows use. It builds no ASC client and writes nothing itself.
@MainActor
final class MCPToolRouter {
    /// What the last apply or resume started over MCP was asked to confirm and what was wrong with the answer.
    private struct ConfirmationOutcome {
        var planId: String
        var needed: JSONValue
        var problems: [String]
    }

    private struct CallPayload: Encodable {
        var tool: String
        var access: String
        /// "notAsked" on a write that ran without Touch ID.
        var touchID: String?
        var arguments: JSONValue
    }

    private let model: AppModel
    private unowned let host: MCPBridgeHost
    private var lastConfirmation: ConfirmationOutcome?

    init(model: AppModel, host: MCPBridgeHost) {
        self.model = model
        self.host = host
    }

    func call(_ request: BridgeRequest) async -> ToolResult {
        guard let name = MCPToolName(rawValue: request.tool), let definition = ToolCatalog.definition(named: request.tool) else {
            return .failure("Unknown tool: \(request.tool)")
        }
        if name == .status { return ToolResult(text: status().line()) }
        let session: WorkspaceSession
        switch model.phase {
        case .needsOwner: return .failure("Purser is not set up yet. Open the app and enter the owner name.")
        case .locked: return .failure("Purser is locked. Unlock it in the app (Touch ID), then try again.")
        case .picking: return .failure("No workspace is open. Open one in the Purser window, then try again.")
        case let .open(open): session = open
        }
        model.noteActivity()
        if definition.access == .ascWrite, !host.writesWithoutTouchID {
            return .failure("Writes to App Store Connect over MCP are off. The owner turns them on in Purser › Settings › Claude (MCP); until then this plan can be applied in the Purser window.")
        }
        if definition.access != .read {
            // Audited before it runs; a write that cannot be audited does not run.
            do {
                var refs = ["tool": name.rawValue]
                if let planId = request.arguments["plan_id"]?.stringValue { refs["plan"] = planId }
                try session.audit.append(.mcpToolCalled, refs: refs,
                                         payload: CallPayload(tool: name.rawValue, access: definition.access.rawValue,
                                                              touchID: definition.access == .ascWrite ? "notAsked" : nil,
                                                              arguments: Self.forAudit(request.arguments)))
            } catch {
                return .failure("The call could not be written to the audit, so it was not run: \(error)")
            }
        }
        do {
            return ToolResult(text: try await run(name, request.arguments, session).line())
        } catch let error as ToolArgumentError {
            return .failure(error.message)
        } catch let error as ProductCreationError {
            return .failure(error.localizedDescription)
        } catch {
            return .failure(String(describing: error))
        }
    }

    // MARK: Status

    private func status() -> JSONValue {
        var result: [String: JSONValue] = ["app_version": .string(AppBuild.version),
                                           "writes_over_mcp_allowed": .bool(host.writesWithoutTouchID)]
        switch model.phase {
        case .needsOwner:
            result["state"] = "not_set_up"
        case .locked:
            result["state"] = "locked"
            result["hint"] = "Unlock Purser in the app with Touch ID."
        case .picking:
            result["state"] = "no_workspace_open"
            result["workspaces"] = .array(model.workspaces.map { .string($0.name) })
            result["hint"] = "Open a workspace in the Purser window; opening one needs Touch ID."
        case let .open(session):
            result["state"] = "open"
            result["workspace"] = ["name": .string(session.config.name), "app_id": .string(session.config.appId),
                                   "bundle_id": .string(session.config.bundleId), "production": .bool(session.config.isProduction)]
            var sync: [String: JSONValue] = ["is_syncing": .bool(session.isSyncing)]
            if let reason = session.syncBlockedReason { sync["unavailable"] = .string(reason) }
            if let snapshot = session.planning.snapshot ?? session.snapshot { sync["catalog_read_at"] = MCPRender.timestamp(snapshot.takenAt) }
            if let last = session.lastSync { sync["last_status"] = .string(last.status.rawValue) }
            result["sync"] = .object(sync)
            if let rate = session.rateLimit {
                result["rate_limit"] = ["limit": MCPRender.number(rate.limit), "remaining": MCPRender.number(rate.remaining)]
            }
            result["open_findings"] = MCPRender.number(session.planning.findings.count)
            let plans = (try? session.planStore.plans(states: nil)) ?? []
            result["plans"] = .object(Dictionary(grouping: plans, by: \.state.rawValue).mapValues { MCPRender.number($0.count) })
            result["apply"] = applyStatus(session)
        }
        return .object(result)
    }

    // MARK: Dispatch

    private func run(_ name: MCPToolName, _ arguments: JSONValue, _ session: WorkspaceSession) async throws -> JSONValue {
        switch name {
        case .status:
            return status()
        case .listProducts:
            return MCPRender.products(try await snapshot(session))
        case .getPrices:
            let snapshot = try await snapshot(session)
            let parsed = PlanArguments(arguments, snapshot: snapshot)
            let reference = try parsed.string("product")
            guard let productId = (try? parsed.subscription(reference)) ?? (try? parsed.iap(reference)),
                  let prices = MCPRender.prices(productAscId: productId, snapshot: snapshot, territories: try parsed.territoryFilter(),
                                                today: session.planning.today) else {
                throw ToolArgumentError("No product with the ASC id or Product ID “\(reference)”. list_products shows the known ones.")
            }
            return prices
        case .getLocalizations:
            let snapshot = try await snapshot(session)
            let parsed = LocalizationArguments(arguments, snapshot: snapshot)
            return MCPRender.localizations(try parsed.owners(), snapshot: snapshot, locales: try parsed.locales())
        case .listFindings:
            _ = try await snapshot(session)
            return MCPRender.findings(session.planning.findingGroups) { session.planning.productName($0) }
        case .listPlans:
            return try listPlans(arguments, session)
        case .getPlan:
            return try await planDetail(session, planId: try planId(arguments), flaggedOnly: arguments["flagged_only"]?.boolValue ?? false,
                                        maxRows: arguments["max_rows"]?.intValue ?? 200)
        case .applyStatus:
            return applyStatus(session)
        case .syncCatalog:
            return try await sync(session)
        case .createRegularPricePlan:
            let parsed = PlanArguments(arguments, snapshot: try await snapshot(session))
            return try await build(try parsed.regular(), reason: parsed.reason, session)
        case .createIAPPricePlan:
            let parsed = PlanArguments(arguments, snapshot: try await snapshot(session))
            return try await build(try parsed.iap(), reason: parsed.reason, session)
        case .createIntroOfferPlan:
            let parsed = PlanArguments(arguments, snapshot: try await snapshot(session))
            return try await build(try parsed.intro(), reason: parsed.reason, session)
        case .createPromoOfferPlan:
            let parsed = PlanArguments(arguments, snapshot: try await snapshot(session))
            return try await build(try parsed.promo(), reason: parsed.reason, session)
        case .createLocalizationPlan:
            let parsed = LocalizationPlanArguments(arguments, snapshot: try await snapshot(session))
            return try await build(try parsed.spec(), reason: parsed.reason, session)
        case .getImportFormat:
            guard let mapping = session.config.importMapping else {
                throw ToolArgumentError("The workspace has no import mapping yet. export_import_template creates one.")
            }
            _ = try await snapshot(session)
            return MCPRender.importMapping(mapping) { session.planning.productName($0) }
        case .exportImportTemplate:
            return try await exportTemplate(session)
        case .createImportPlan:
            return try await importPlan(arguments, session)
        case .replan:
            return try await replan(try planId(arguments), session)
        case .cancelPlan:
            let id = try planId(arguments)
            try await planningAction(session) { await session.planning.cancel(planId: id) }
            return try storedSummary(id, session)
        case .ackFindings:
            return try await ack(arguments, session)
        case .withdrawWritten:
            let newId = try await session.withdrawWritten(planId: try planId(arguments))
            await session.planning.reload()
            return try await planDetail(session, planId: newId, flaggedOnly: false, maxRows: 50)
        case .replanRest:
            let newId = try await session.replanRest(planId: try planId(arguments))
            await session.planning.reload()
            return try await planDetail(session, planId: newId, flaggedOnly: false, maxRows: 50)
        case .closePlan:
            let id = try planId(arguments)
            try await session.closePlan(planId: id, reason: try text(arguments, "reason"))
            await session.planning.reload()
            return try storedSummary(id, session)
        case .applyPlan:
            return try await apply(arguments, session, resume: false)
        case .resumePlan:
            return try await apply(arguments, session, resume: true)
        case .pauseApply:
            guard session.applyController.isRunning else { throw ToolArgumentError("No apply is running.") }
            session.applyController.pause()
            await waitWhileRunning(session, seconds: 15)
            return applyStatus(session)
        case .abortPlan:
            let id = try planId(arguments)
            _ = try await session.abort(planId: id)
            await session.planning.reload()
            return try storedSummary(id, session)
        case .previewProducts:
            let request = try productRequest(arguments)
            let existing = try await session.makeProductCreator().existing()
            let steps = ProductCreationPlanner.steps(request, existing: existing)
            return ["steps": .array(steps.map { .string(Self.describe($0)) }),
                    "note": steps.isEmpty ? "Everything in the request already exists." : "create_products runs these steps. A Product ID can never be used again."]
        case .createProducts:
            let request = try productRequest(arguments)
            let reports = try await session.makeProductCreator(gate: MCPWriteGate()).create(request)
            return ["steps": .array(reports.map(Self.describe)),
                    "note": "Run sync_catalog to see the new products. They still need metadata and App Review in App Store Connect."]
        case .previewClone:
            // While a run writes, what it would list still changes (a timed-out clone_products keeps running in the app).
            if let running = session.productRuns.running { return MCPRender.productRunInProgress(running) }
            let snapshot = try await snapshot(session)
            let request = try cloneRequest(arguments, snapshot)
            return MCPRender.cloneSteps(try await session.makeProductCreator().previewClone(request, snapshot: snapshot), snapshot: snapshot)
        case .cloneProducts:
            // The answer leaves before the helper gives up on the call, counted from here: the clone itself uses part of it.
            let answerBy = ContinuousClock.now + .seconds(BridgeClient.callTimeout - Self.answerMargin)
            // The run stays marked until the drafts are built (the task below releases the claim), so a second
            // clone_products or preview_clone does not meet a clone whose drafts are still being built.
            let claim = try session.productRuns.claim(.clone)
            let snapshot: CatalogSnapshot, request: CloneRequest, report: CloneReport
            do {
                snapshot = try await self.snapshot(session)
                request = try cloneRequest(arguments, snapshot)
                report = try await session.makeProductCreator(gate: MCPWriteGate()).clone(request, snapshot: snapshot, holding: claim)
            } catch {
                claim.release()
                throw error
            }
            // The sync and the drafts may outlast that; they finish in the app either way.
            let pending = PendingCloneDrafts()
            Task { pending.outcome = await session.prepareCloneDrafts(created: report.created, copy: request.copy,
                                                                     offerCodeSuffix: request.offerCodeSuffix, holding: claim) }
            while pending.outcome == nil, ContinuousClock.now < answerBy {
                model.noteActivity()
                try? await Task.sleep(for: .milliseconds(200))
            }
            return MCPRender.cloneResult(report, drafts: pending.outcome, snapshot: snapshot)
        }
    }

    // MARK: Reads

    private func snapshot(_ session: WorkspaceSession) async throws -> CatalogSnapshot {
        if session.planning.snapshot == nil { await session.planning.reload() }
        guard let snapshot = session.planning.snapshot else {
            throw ToolArgumentError("The catalog is empty. Run sync_catalog first.")
        }
        return snapshot
    }

    private func listPlans(_ arguments: JSONValue, _ session: WorkspaceSession) throws -> JSONValue {
        var states: Set<PlanState>?
        if let names = arguments["states"]?.arrayValue, !names.isEmpty {
            states = Set(try names.map { value -> PlanState in
                guard let state = value.stringValue.flatMap(PlanState.init(rawValue:)) else {
                    throw ToolArgumentError("Unknown plan state \(value.line()); use \(PlanState.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                return state
            })
        }
        let plans = try session.planStore.plans(states: states).sorted { $0.createdAt > $1.createdAt }
        return ["count": MCPRender.number(plans.count), "plans": .array(plans.prefix(100).map(MCPRender.planSummary))]
    }

    private func storedSummary(_ planId: String, _ session: WorkspaceSession) throws -> JSONValue {
        guard let plan = try session.planStore.plan(id: planId) else { throw ToolArgumentError("No plan with the id “\(planId)”.") }
        return MCPRender.planSummary(plan)
    }

    /// Reads the plan and builds its rows off the main actor, as the Plan screen does.
    private func planDetail(_ session: WorkspaceSession, planId: String, flaggedOnly: Bool, maxRows: Int) async throws -> JSONValue {
        let snapshot = try await snapshot(session)
        let store = session.planStore
        let config = session.config
        let today = session.planning.today
        let loaded = try await Task.detached(priority: .userInitiated) { () -> (StoredPlan, [StoredItem], [PlanDiffRow])? in
            guard let plan = try store.plan(id: planId) else { return nil }
            let items = try store.items(planId: planId)
            let spec = try JSONCoding.decode(PlanSpec.self, from: plan.specJSON)
            let rows = PlanDiff.rows(items: items.map(\.item), verdicts: plan.verdicts, spec: spec, snapshot: snapshot, config: config, today: today)
            return (plan, items, rows)
        }.value
        guard let (plan, items, rows) = loaded else { throw ToolArgumentError("No plan with the id “\(planId)”. list_plans shows the known ones.") }
        let versions = ReadyForReview.status(plan: plan, items: items, metadata: snapshot.metadata)
        return MCPRender.plan(plan, items: items, rows: rows, appName: config.name, productName: { session.planning.productName($0) },
                              flaggedOnly: flaggedOnly, maxRows: maxRows,
                              readyForReview: MCPRender.readyForReview(versions.ready) { snapshot.ownerName($0) },
                              incompleteVersions: MCPRender.incompleteVersions(versions.incomplete) { snapshot.ownerName($0) })
    }

    private func sync(_ session: WorkspaceSession) async throws -> JSONValue {
        if let reason = session.syncBlockedReason { throw ToolArgumentError("Sync is unavailable: \(reason)") }
        if !session.isSyncing {
            Task { await session.syncNow() }
            // syncNow sets isSyncing before its first suspension; give the task its turn.
            await Task.yield()
        }
        for _ in 0..<450 where session.isSyncing {
            model.noteActivity()
            try? await Task.sleep(for: .milliseconds(200))
        }
        if session.isSyncing {
            return ["status": "running", "note": "The sync is still running; purser_status shows when it ends."]
        }
        if let message = session.errorMessage {
            session.errorMessage = nil
            throw ToolArgumentError(message)
        }
        var result: [String: JSONValue] = ["status": .string(session.lastSync?.status.rawValue ?? "unknown"),
                                           "open_findings": MCPRender.number(session.planning.findings.count)]
        if let last = session.lastSync {
            result["requests"] = MCPRender.number(last.requestCount)
            result["new_findings"] = MCPRender.number(last.newFindings.count)
        }
        return .object(result)
    }

    // MARK: Plans

    /// Runs a PlanningModel action and turns the message it would show in the window into the tool's error.
    private func planningAction(_ session: WorkspaceSession, _ action: () async -> Void) async throws {
        session.planning.errorMessage = nil
        await action()
        if let message = session.planning.errorMessage {
            session.planning.errorMessage = nil
            throw ToolArgumentError(message)
        }
    }

    private func build(_ spec: PlanSpec, reason: String?, _ session: WorkspaceSession) async throws -> JSONValue {
        var built = false
        try await planningAction(session) { built = await session.planning.build(spec, reason: reason) }
        guard built, let id = session.planning.shownPlanId else { throw ToolArgumentError("The plan could not be built.") }
        return try await planDetail(session, planId: id, flaggedOnly: false, maxRows: 50)
    }

    /// The template goes through a file in the app's own temporary folder, as the Save panel path does.
    private func exportTemplate(_ session: WorkspaceSession) async throws -> JSONValue {
        let snapshot = try await snapshot(session)
        // A saved mapping is exported as it is; only a workspace without one gets the app's default template.
        if let mapping = session.config.importMapping {
            let export = try ImportTableExport.csv(mapping: mapping, snapshot: snapshot, today: session.planning.today)
            var result: [String: JSONValue] = ["csv": .string(export.text), "mapping_version": MCPRender.number(mapping.version),
                                               "mapping": "unchanged", "columns": MCPRender.importMapping(mapping) { session.planning.productName($0) }["columns"] ?? [],
                                               "empty_written_cells": MCPRender.number(export.emptyCells)]
            if !export.skipped.isEmpty { result["territories_without_a_known_name"] = .array(export.skipped.map { .string($0.rawValue) }) }
            return .object(result)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("purser-import-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let export = try session.planning.exportImportTemplate(to: url)
        var result: [String: JSONValue] = ["csv": .string(try String(contentsOf: url, encoding: .utf8)),
                                           "products": MCPRender.number(export.productCount),
                                           "territories": MCPRender.number(export.territoryCount),
                                           "mapping_version": MCPRender.number(export.mappingVersion), "mapping": "created"]
        if !export.withoutPrice.isEmpty { result["left_out_without_a_price"] = .array(export.withoutPrice.map(JSONValue.string)) }
        if !export.skippedTerritories.isEmpty {
            result["territories_without_a_known_name"] = .array(export.skippedTerritories.map { .string($0.rawValue) })
        }
        return .object(result)
    }

    private func importPlan(_ arguments: JSONValue, _ session: WorkspaceSession) async throws -> JSONValue {
        let parsed = PlanArguments(arguments, snapshot: try await snapshot(session))
        guard let text = arguments["csv_text"]?.stringValue, !text.isEmpty else {
            throw ToolArgumentError("Give csv_path or csv_text.")
        }
        guard let mapping = session.config.importMapping else {
            throw ToolArgumentError("The workspace has no import mapping yet. export_import_template creates one.")
        }
        var outcome: ImportOutcome?
        try await planningAction(session) { outcome = await session.planning.importCSV(text: text) }
        guard let outcome else { throw ToolArgumentError("The table could not be read.") }
        guard !outcome.hasBlock else {
            throw ToolArgumentError("The table was refused, nothing was planned. " + outcome.verdicts.map { "\($0.rule.rawValue): \($0.message)" }.joined(separator: " "))
        }
        let spec = try parsed.importTable(outcome.table, mapping: mapping)
        guard case let .importTable(importSpec) = spec else { throw ToolArgumentError("The table could not be planned.") }
        var checks: [String: JSONValue] = [:]
        if case let .object(report) = ImportChecks.report(spec: importSpec, mapping: mapping, snapshot: parsed.snapshot, today: session.planning.today,
                                                          productName: { session.planning.productName($0) }) { checks = report }
        checks["table_sha256"] = .string(outcome.table.sha256)
        if let source = arguments[BridgeRequest.csvSourceKey]?.stringValue { checks["file_read"] = .string(source) }
        if !outcome.verdicts.isEmpty { checks["import_verdicts"] = .array(outcome.verdicts.map(MCPRender.verdict)) }
        if arguments["validate_only"]?.boolValue == true {
            return ["validated": true, "plan": nil, "written_columns": .array(importSpec.writeColumns.map(JSONValue.string)), "checks": .object(checks)]
        }
        var built = false
        try await planningAction(session) { built = await session.planning.build(spec, reason: parsed.reason) }
        guard built, let id = session.planning.shownPlanId else { throw ToolArgumentError("The plan could not be built.") }
        guard case var .object(result) = try await planDetail(session, planId: id, flaggedOnly: false, maxRows: 50) else {
            throw ToolArgumentError("The plan \(id) was saved but cannot be read.")
        }
        result["checks"] = .object(checks)
        if let presentation = session.planning.presentation, presentation.id == id, let diffs = presentation.checkDiffs {
            result["check_differences_total"] = MCPRender.number(diffs.count)
            result["check_differences"] = MCPRender.checkDiffs(diffs)
        }
        return .object(result)
    }

    /// The audit keeps the size of an imported table, not its text: the plan stores the table and its hash.
    private static func forAudit(_ arguments: JSONValue) -> JSONValue {
        guard case var .object(members) = arguments, let text = members["csv_text"]?.stringValue else { return arguments }
        members["csv_text"] = .string("<\(text.count) characters>")
        return .object(members)
    }

    private func replan(_ planId: String, _ session: WorkspaceSession) async throws -> JSONValue {
        if !session.planning.plans.contains(where: { $0.id == planId }) { await session.planning.reload() }
        try await planningAction(session) { await session.planning.replan(planId: planId) }
        guard let newId = session.planning.shownPlanId, newId != planId else {
            throw ToolArgumentError("The plan was not re-planned; only Draft and Stale plans can be.")
        }
        return try await planDetail(session, planId: newId, flaggedOnly: false, maxRows: 50)
    }

    private func ack(_ arguments: JSONValue, _ session: WorkspaceSession) async throws -> JSONValue {
        _ = try await snapshot(session)
        let groupId = try text(arguments, "group_id")
        guard let group = session.planning.findingGroups.first(where: { $0.id == groupId }) else {
            throw ToolArgumentError("No open finding group with the id “\(groupId)”. list_findings shows the open ones.")
        }
        let reason = try text(arguments, "reason")
        var acknowledged = false
        try await planningAction(session) { acknowledged = await session.planning.ack(group, reason: reason) }
        guard acknowledged else { throw ToolArgumentError("The findings were not acknowledged.") }
        return ["acknowledged": MCPRender.number(group.findings.count), "open_findings": MCPRender.number(session.planning.findings.count)]
    }

    // MARK: Apply

    private func apply(_ arguments: JSONValue, _ session: WorkspaceSession, resume: Bool) async throws -> JSONValue {
        let id = try planId(arguments)
        let controller = session.applyController
        guard !controller.isRunning else { throw ToolArgumentError("An apply is already running in this workspace; see apply_status.") }
        guard let plan = try session.planStore.plan(id: id) else { throw ToolArgumentError("No plan with the id “\(id)”.") }
        if resume {
            guard plan.state == .applying, plan.pauseReason != nil else {
                throw ToolArgumentError("Only a paused apply can be resumed; this plan is \(plan.state.rawValue).")
            }
        } else {
            guard plan.state == .draft else { throw ToolArgumentError("Only a Draft can be applied; this plan is \(plan.state.rawValue).") }
        }
        let checked = Set((arguments["checked_risk_classes"]?.arrayValue ?? []).compactMap(\.stringValue))
        // Calling the tool is the acceptance; every other field must still satisfy the ConfirmationValidator.
        let response = ConfirmationResponse(accepted: true, acknowledgedExclusions: arguments["acknowledge_exclusions"]?.boolValue ?? false,
                                            typedAppName: arguments["typed_app_name"]?.stringValue, reason: arguments["reason"]?.stringValue,
                                            checkedRiskClasses: checked)
        lastConfirmation = nil
        let delegated = DelegatedApply(confirm: { [weak self] request in
            await self?.note(request, response)
            return response
        }, gate: MCPWriteGate())
        if resume { controller.resume(planId: id, delegated: delegated) } else { controller.apply(planId: id, delegated: delegated) }
        await waitWhileRunning(session, seconds: 20)
        return applyStatus(session)
    }

    private func note(_ request: ConfirmationRequest, _ response: ConfirmationResponse) {
        lastConfirmation = ConfirmationOutcome(
            planId: request.planId,
            needed: MCPRender.confirmationNeeded(level: request.level, excluded: request.excluded.count, verdicts: request.verdicts,
                                                 appName: request.appName),
            problems: ConfirmationValidator.problems(request: request, response: response))
    }

    private func waitWhileRunning(_ session: WorkspaceSession, seconds: Int) async {
        for _ in 0..<(seconds * 5) where session.applyController.isRunning {
            model.noteActivity()
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func applyStatus(_ session: WorkspaceSession) -> JSONValue {
        let controller = session.applyController
        var result: [String: JSONValue] = [:]
        var planId: String?
        switch controller.phase {
        case .idle:
            result["phase"] = "idle"
        case let .running(id):
            result["phase"] = "running"
            result["note"] = "Poll apply_status until the phase changes."
            planId = id
        case let .paused(id, reason):
            result["phase"] = "paused"
            result["pause_reason"] = .string(reason.rawValue)
            planId = id
        case let .finished(id, state):
            result["phase"] = "finished"
            result["plan_state"] = .string(state.rawValue)
            planId = id
        case let .failed(id, message):
            result["phase"] = "failed"
            result["message"] = .string(message)
            planId = id
        }
        if let planId {
            result["plan_id"] = .string(planId)
            let plan = try? session.planStore.plan(id: planId)
            if let plan { result["plan"] = MCPRender.planSummary(plan) }
            if let items = try? session.planStore.items(planId: planId) {
                result["item_states"] = .object(Dictionary(grouping: items, by: \.state.rawValue).mapValues { MCPRender.number($0.count) })
                if let plan {
                    let snapshot = session.planning.snapshot
                    let versions = ReadyForReview.status(plan: plan, items: items, metadata: snapshot?.metadata ?? [:])
                    let name: (LocalizationOwner) -> String = { snapshot?.ownerName($0) ?? $0.ascId }
                    if let ready = MCPRender.readyForReview(versions.ready, ownerName: name) { result["ready_for_review"] = ready }
                    if let incomplete = MCPRender.incompleteVersions(versions.incomplete, ownerName: name) {
                        result["incomplete_versions"] = incomplete
                    }
                }
            }
        }
        if controller.total > 0 {
            result["done"] = MCPRender.number(controller.done)
            result["total"] = MCPRender.number(controller.total)
        }
        if let budget = controller.budgetRemaining { result["rate_budget_remaining"] = MCPRender.number(budget) }
        if let eta = controller.etaMinutes { result["eta_minutes"] = MCPRender.number(eta) }
        if let confirmation = lastConfirmation, confirmation.planId == planId {
            result["confirmation"] = ["needed": confirmation.needed, "accepted": .bool(confirmation.problems.isEmpty),
                                      "problems": .array(confirmation.problems.map(JSONValue.string))]
            if !confirmation.problems.isEmpty {
                result["note"] = "Nothing was written. Call the tool again with the missing confirmation fields."
            }
        }
        return .object(result)
    }

    // MARK: Products

    /// Seconds before the helper's timeout at which clone_products stops waiting for the drafts and answers.
    private static let answerMargin: TimeInterval = 15

    /// The price drafts of a clone, prepared by a task of their own.
    @MainActor private final class PendingCloneDrafts {
        var outcome: CloneDraftOutcome?
    }

    private func cloneRequest(_ arguments: JSONValue, _ snapshot: CatalogSnapshot) throws -> CloneRequest {
        let request = try CloneArguments.request(arguments, snapshot: snapshot)
        let problems = ClonePlanner.problems(request, snapshot: snapshot)
        guard problems.isEmpty else { throw ToolArgumentError(problems.joined(separator: " ")) }
        return request
    }

    private func productRequest(_ arguments: JSONValue) throws -> ProductCreationRequest {
        let request = try PlanArguments.productCreation(arguments)
        let problems = ProductCreationPlanner.problems(request)
        guard problems.isEmpty else { throw ToolArgumentError(problems.joined(separator: " ")) }
        return request
    }

    private static func describe(_ step: ProductCreationStep) -> String {
        switch step {
        case let .group(name): return "create the subscription group “\(name)”"
        case let .subscription(product): return "create the subscription \(product.productId) (\(product.period.rawValue))"
        case let .subscriptionAvailability(productId): return "set the territories of the subscription \(productId)"
        case let .nonConsumable(product): return "create the non-consumable \(product.productId)"
        case let .nonConsumableAvailability(productId): return "set the territories of the non-consumable \(productId)"
        }
    }

    private static func describe(_ report: ProductCreationReport) -> JSONValue {
        var entry: [String: JSONValue] = ["step": .string(describe(report.step))]
        switch report.outcome {
        case let .created(ascId):
            entry["outcome"] = "created"
            entry["asc_id"] = .string(ascId)
        case let .failed(message):
            entry["outcome"] = "failed"
            entry["message"] = .string(message)
        case let .skipped(message):
            entry["outcome"] = "skipped"
            entry["message"] = .string(message)
        }
        return .object(entry)
    }

    // MARK: Arguments

    private func planId(_ arguments: JSONValue) throws -> String { try text(arguments, "plan_id") }

    private func text(_ arguments: JSONValue, _ key: String) throws -> String {
        guard let value = arguments[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw ToolArgumentError("“\(key)” is required.")
        }
        return value
    }
}
