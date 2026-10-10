import Foundation
import UserNotifications
import MacroSIPCore

/// Incoming-call notification with Answer / Decline actions (SCREENS.md 6.3).
@MainActor
final class CallNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CallNotifications()

    private let categoryID = "INCOMING_CALL"
    private let answerID = "ANSWER"
    private let declineID = "DECLINE"

    /// Needs a real .app bundle; demo launches skip it so no permission dialog covers screenshots.
    private var available: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && !LaunchOptions.current.isDemo
    }

    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    func setup() {
        guard available else { return }
        center.delegate = self
        let answer = UNNotificationAction(identifier: answerID, title: L.incomingAnswer, options: [])
        let decline = UNNotificationAction(identifier: declineID, title: L.incomingDecline, options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: categoryID, actions: [answer, decline], intentIdentifiers: [], options: [])
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func identifier(_ id: CallID) -> String { "incoming-\(id.serial)" }

    func post(for call: CallInfo, model: AppModel) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = L.incomingNotificationTitle(model.accountName(call.accountID))
        content.subtitle = model.name(for: call.remote)
        content.body = call.remote.number
        content.categoryIdentifier = categoryID
        content.userInfo = ["raw": Int(call.id.raw), "serial": Int(call.id.serial)]
        center.add(UNNotificationRequest(identifier: identifier(call.id), content: content, trigger: nil))
    }

    func remove(_ id: CallID) {
        guard available else { return }
        center.removeDeliveredNotifications(withIdentifiers: [identifier(id)])
        center.removePendingNotificationRequests(withIdentifiers: [identifier(id)])
    }

    func removeAll() {
        guard available else { return }
        center.removeAllDeliveredNotifications()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        guard let raw = info["raw"] as? Int, let serial = info["serial"] as? Int else { return }
        await MainActor.run {
            let model = AppModel.shared
            guard let call = model.calls.first(where: { Int($0.id.raw) == raw && Int($0.id.serial) == serial }) else { return }
            switch action {
            case answerID: model.answer(call.id)
            case declineID: model.decline(call.id)
            default: model.showMainWindow()
            }
        }
    }
}
