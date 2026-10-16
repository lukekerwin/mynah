import Foundation
import UserNotifications

/// Meeting notifications: recording started, "Record this call?" (Ask mode),
/// transcript/summary ready, problems. Clicking one opens the meeting.
@MainActor
final class MeetingNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let askCategory = "MEETING_ASK"
    static let recordAction = "RECORD"
    static let ignoreAction = "IGNORE"

    var onRecord: (() -> Void)?
    var onIgnore: (() -> Void)?
    var onOpen: ((String?) -> Void)?

    private var center: UNUserNotificationCenter { .current() }

    func setUp() {
        center.delegate = self
        let record = UNNotificationAction(identifier: Self.recordAction, title: "Record", options: [])
        let ignore = UNNotificationAction(identifier: Self.ignoreAction, title: "Ignore", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.askCategory, actions: [record, ignore], intentIdentifiers: [],
                                   options: [.customDismissAction]),
        ])
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func post(_ title: String, _ body: String, meetingID: String? = nil, ask: Bool = false, id: String = UUID().uuidString) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if ask { content.categoryIdentifier = Self.askCategory }
        if let meetingID { content.userInfo = ["meetingID": meetingID] }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func remove(id: String) {
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let meetingID = response.notification.request.content.userInfo["meetingID"] as? String
        Task { @MainActor in
            switch action {
            case Self.recordAction: self.onRecord?()
            case Self.ignoreAction, UNNotificationDismissActionIdentifier: self.onIgnore?()
            default: self.onOpen?(meetingID)
            }
        }
        completionHandler()
    }
}
