//
//  PitHubNotifier.swift
//  PitHubCore
//
//  本机本地通知：上传完成、快捷指令触发、异常断连等。
//  使用 UNUserNotificationCenter（公开 API），不涉及远程推送。
//

import Foundation
import UserNotifications

public final class PitHubNotifier {

    public static let shared = PitHubNotifier()

    private init() {}

    public func requestAuthorization(completion: ((Bool) -> Void)? = nil) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                PitHubLog.error("通知权限请求失败：\(error.localizedDescription)")
            }
            DispatchQueue.main.async { completion?(granted) }
        }
    }

    public func notify(title: String, body: String, identifier: String = UUID().uuidString) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                PitHubLog.error("本地通知发送失败：\(error.localizedDescription)")
            }
        }
    }
}
