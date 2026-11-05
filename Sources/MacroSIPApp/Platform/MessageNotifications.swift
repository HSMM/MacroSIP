import Foundation
import UserNotifications

/// One notification per incoming text message (SCREENS.md 14.4). Title: the sender, subtitle: the account, body: the text,
/// no action buttons and no sound (the "New message" sound event is the only sound). `threadIdentifier` is the
/// conversation, so Notification Center groups by conversation. A click opens the conversation. The notification
/// center's delegate is `CallNotifications`; it hands message responses to `handle(_:)`.
@MainActor
final class MessageNotifications {
    static let shared = MessageNotifications()

    nonisolated static let categoryID = "MESSAGE"
    private nonisolated static let conversationKey = "conversation"

    /// What `post` was asked for (the newest 64), also when the notification center is not available (demo launches):
    /// the self-test reads it.
    struct Posted: Equatable {
        var conversation: UUID
        var title: String
        var subtitle: String
        var body: String
    }
    private(set) var posted: [Posted] = []

    /// Needs a real .app bundle; demo launches skip it so no permission dialog covers screenshots.
    private var available: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && !LaunchOptions.current.isDemo
    }

    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    static var category: UNNotificationCategory {
        UNNotificationCategory(identifier: categoryID, actions: [], intentIdentifiers: [], options: [])
    }

    func post(text: String, from sender: String, account: String, conversation: UUID) {
        posted.append(Posted(conversation: conversation, title: sender, subtitle: account, body: text))
        if posted.count > 64 { posted.removeFirst(posted.count - 64) }
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = sender
        content.subtitle = account
        content.body = text
        content.categoryIdentifier = Self.categoryID
        content.threadIdentifier = conversation.uuidString
        content.userInfo = [Self.conversationKey: conversation.uuidString]
        center.add(UNNotificationRequest(identifier: "message-\(UUID().uuidString)", content: content, trigger: nil))
    }

    func clearPosted() { posted = [] }

    /// The conversation was read in the app or deleted: its notifications leave Notification Center.
    func remove(conversation: UUID) {
        guard available else { return }
        let thread = conversation.uuidString
        Task.detached {
            let ids = await Self.deliveredIdentifiers(thread: thread)
            guard !ids.isEmpty else { return }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    private nonisolated static func deliveredIdentifiers(thread: String) async -> [String] {
        await UNUserNotificationCenter.current().deliveredNotifications()
            .filter { $0.request.content.threadIdentifier == thread }
            .map(\.request.identifier)
    }

    /// The conversation a message notification belongs to (`userInfo` of its request).
    nonisolated static func conversation(in userInfo: [AnyHashable: Any]) -> UUID? {
        (userInfo[conversationKey] as? String).flatMap(UUID.init(uuidString:))
    }
}
