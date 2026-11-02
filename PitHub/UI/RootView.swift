//
//  RootView.swift
//  PitHub
//

import SwiftUI
import PitHubCore

struct RootView: View {
    let services: AppServices

    @EnvironmentObject private var runtime: PitHubRuntime
    @AppStorage("pithub.onboarded") private var onboarded = false
    @State private var showOnboarding = false

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("控制台", systemImage: "square.grid.2x2.fill") }

            PluginsView(services: services)
                .tabItem { Label("插件", systemImage: "puzzlepiece.extension.fill") }

            LogsView()
                .tabItem { Label("日志", systemImage: "list.bullet.rectangle.portrait.fill") }

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
        .onAppear {
            if !onboarded { showOnboarding = true }
        }
        .alert("欢迎使用 PitHub", isPresented: $showOnboarding) {
            Button("开始使用") { onboarded = true }
            Button("稍后", role: .cancel) {
                onboarded = true
            }
        } message: {
            Text("PitHub 会把这台 iPhone 变成家庭微型服务器：请保持插电、保持 App 在前台或屏幕常亮。iOS 会在锁屏/后台一段时间后挂起 App，这是系统限制，无法绕过。\n\n首次登录网页的默认密码是 pithub，请尽快在设置里修改。")
        }
    }
}
