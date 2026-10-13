import Foundation
import OSLog
import Domain
import Store
import ASCClient
import Executor

/// Hourly pass for the open workspace: the daily audit chain head on Slack (when enabled) and the daily NO_OFFER reminder.
@MainActor
struct ChainHeadScheduler {
    let session: WorkspaceSession
    private let notifier = Notifier()
    private let logger = Logger(subsystem: "com.lubosbury.purser", category: "chain-head")

    init(session: WorkspaceSession) { self.session = session }

    func run() async {
        while !Task.isCancelled {
            await publishIfDue()
            remindNoOfferIfDue()
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    func publishIfDue() async {
        let key = "purser.chainHead.\(session.config.id.uuidString).lastDay"
        let today = CalendarDate.today(now: Date()).iso
        guard UserDefaults.standard.string(forKey: key) != today, let url = session.slackWebhookURL() else { return }
        do {
            if try await SlackChainHeadPublisher(transport: URLSessionTransport(), audit: session.audit).publish(webhook: url) {
                UserDefaults.standard.set(today, forKey: key)
            }
        } catch {
            // The day stays due, so the next hourly pass retries. The error text may contain the webhook URL: keep it private.
            logger.error("Chain head publish failed: \(String(describing: error), privacy: .private)")
        }
    }

    /// Spec §6: cells flagged NO_OFFER get one notification a day per workspace until their end date D passes
    /// (the same per-workspace day-key scheme as the chain head).
    func remindNoOfferIfDue() {
        let key = "purser.noOffer.\(session.config.id.uuidString).lastDay"
        let today = CalendarDate.today(now: Date())
        guard UserDefaults.standard.string(forKey: key) != today.iso, let plans = try? session.planStore.plans(states: nil) else { return }
        var cells = Set<CellKey>()
        var earliest: CalendarDate?
        for plan in plans where plan.state != .cancelled {
            for stored in (try? session.planStore.items(planId: plan.id)) ?? [] where stored.item.flags.contains(.noOffer) {
                guard case let .endIntro(_, end) = stored.item.payload, end > today else { continue }
                cells.insert(stored.item.cell)
                earliest = min(earliest ?? end, end)
            }
        }
        guard let earliest, !cells.isEmpty else { return }
        notifier.requestAuthorization()
        notifier.noOffer(workspace: session.config.name, cells: cells.count, before: earliest)
        UserDefaults.standard.set(today.iso, forKey: key)
    }
}
