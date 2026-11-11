import Foundation
import AppKit
import UserNotifications

enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func send(title: String, body: String, playSound: Bool, notifyEnabled: Bool) {
        if playSound { NSSound(named: .init("Basso"))?.play() }
        guard notifyEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = playSound ? .default : nil
        content.categoryIdentifier = "NAS_ALERT"

        let req = UNNotificationRequest(identifier: "nasmon-\(UUID().uuidString)",
                                        content: content,
                                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.4, repeats: false))
        UNUserNotificationCenter.current().add(req) { err in
            if err != nil {
                DispatchQueue.main.async {
                    NSApp.requestUserAttention(.criticalRequest)
                }
            }
        }
    }
}
