import Foundation
import UserNotifications
import Domain

/// macOS notifications on completion, pause and NO_OFFER; no prices or ids in the text.
@MainActor
final class Notifier {
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func applyFinished(workspace: String, state: PlanState) {
        post(title: "Purser · \(workspace)", body: "Apply finished: \(state.rawValue)")
    }

    func applyPaused(workspace: String, reason: PauseReason, done: Int, total: Int) {
        var body = "Apply paused (\(reason.rawValue.uppercased())) at \(done)/\(total)"
        if reason == .agreement { body += ". The Account Holder must accept the pending agreement in App Store Connect." }
        post(title: "Purser · \(workspace)", body: body)
    }

    func applyFailed(workspace: String, message: String) {
        post(title: "Purser · \(workspace)", body: "Apply stopped: \(message)")
    }

    /// Spec §6: a live intro ended by PATCH_END whose replacement POST was not written leaves the cell without an offer from D.
    func noOffer(workspace: String, cells: Int, before: CalendarDate) {
        post(title: "Purser · \(workspace)", body: "\(cells) cells without an offer (NO_OFFER), re-plan before \(before.iso)")
    }

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil),
                                               withCompletionHandler: nil)
    }
}
