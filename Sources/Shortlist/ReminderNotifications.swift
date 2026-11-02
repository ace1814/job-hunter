import Foundation
import ShortlistCore
import UserNotifications

/// Puts reminders in the system's hands, so they arrive with Shortlist closed. There's one per day
/// at most, and they're rewritten whenever your reminders change.
enum ReminderNotifications {
    private static let prefix = "followups-"
    /// macOS keeps only so many waiting at once.
    private static let limit = 60

    /// The notification center crashes anything that isn't a real app bundle.
    static var isAvailable: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

    static func update(_ announcements: [Reminders.Announcement]) async {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        let waiting = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: waiting)
        guard !announcements.isEmpty else { return }

        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        for announcement in announcements.prefix(limit) {
            let content = UNMutableNotificationContent()
            content.title = announcement.title
            content.body = announcement.body
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: announcement.fireAt, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: prefix + announcement.day, content: content, trigger: trigger))
        }
    }
}

/// Without this, macOS hides a notification while Shortlist is the frontmost app.
final class NotificationBanners: NSObject, UNUserNotificationCenterDelegate, Sendable {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
