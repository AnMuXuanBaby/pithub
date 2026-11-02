//
//  PitHubApp.swift
//  PitHub
//
//  App 入口：构建插件、Runtime，并处理锁屏/通知等系统事件。
//

import SwiftUI
import UserNotifications
import UIKit
import PitHubCore
import PitHubFilePit
import PitHubPhotoNode
import PitHubClipHub
import PitHubDashLink

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

final class LockStateCoordinator {
    private let runtime: PitHubRuntime
    private var resumeAfterUnlock = false
    private var observers: [NSObjectProtocol] = []

    init(runtime: PitHubRuntime) {
        self.runtime = runtime
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            guard self.runtime.currentSettings.backgroundPolicy == .pauseOnLock,
                  self.runtime.isRunning else { return }
            self.resumeAfterUnlock = true
            self.runtime.stop()
        })
        observers.append(center.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.resumeAfterUnlock else { return }
            self.resumeAfterUnlock = false
            self.runtime.start()
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

final class AppServices: ObservableObject {
    let runtime: PitHubRuntime
    let filePit: FilePitPlugin
    let photoNode: PhotoNodePlugin
    let clipHub: ClipHubPlugin
    let dashLink: DashLinkPlugin

    private let notificationDelegate = NotificationDelegate()
    private var lockCoordinator: LockStateCoordinator?

    init() {
        let filePit = FilePitPlugin()
        let photoNode = PhotoNodePlugin()
        let clipHub = ClipHubPlugin()
        let dashLink = DashLinkPlugin()
        self.filePit = filePit
        self.photoNode = photoNode
        self.clipHub = clipHub
        self.dashLink = dashLink
        self.runtime = PitHubRuntime(plugins: [filePit, photoNode, clipHub, dashLink])

        UNUserNotificationCenter.current().delegate = notificationDelegate
        self.lockCoordinator = LockStateCoordinator(runtime: runtime)

        // 常驻服务型 App：启动后自动拉起 HTTP 服务
        runtime.start()
    }
}

@main
struct PitHubApp: App {
    @StateObject private var services = AppServices()

    var body: some Scene {
        WindowGroup {
            RootView(services: services)
                .environmentObject(services.runtime)
                .preferredColorScheme(.dark)
                .tint(PitHubPalette.accent)
        }
    }
}
