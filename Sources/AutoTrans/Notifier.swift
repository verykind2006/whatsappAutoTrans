import Foundation
import AppKit
import UserNotifications

/// 系统通知：单聊收到新消息时，在屏幕右上角显示中文翻译；点通知就打开 autoTrans 里的这个聊天。
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    /// 点了通知 → 打开哪个聊天（由 AppModel 设置）
    var onOpenChat: ((Int) -> Void)?

    /// 第一次会弹系统提示「autoTrans 想发送通知」，用户点允许后才会显示
    func setup() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(chatID: Int, messageID: Int, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "chat-\(chatID)"     // 同一个人的通知归在一起
        content.userInfo = ["chatID": chatID]
        let req = UNNotificationRequest(identifier: "msg-\(messageID)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let chatID = response.notification.request.content.userInfo["chatID"] as? Int
        Task { @MainActor in
            if let chatID { Notifier.shared.onOpenChat?(chatID) }
            WhatsAppSender.bringAutoTransToFront()
        }
        completionHandler()
    }

    /// autoTrans 在前台时也显示（正在看的那个聊天不会发通知，由 AppModel 判断）
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}
