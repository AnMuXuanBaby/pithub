//
//  SettingsView.swift
//  PitHub
//
//  本机设置与网页设置共用同一份 PitHubSettings（数据同源）。
//

import SwiftUI
import UIKit
import PitHubCore

struct SettingsView: View {
    @EnvironmentObject private var runtime: PitHubRuntime

    @State private var tunnelPublicURL = ""
    @State private var relayURL = ""
    @State private var relayToken = ""
    @State private var blockedExtensions = ""
    @State private var newAccessPassword = ""
    @State private var newAdminPassword = ""
    @State private var cacheBytes: Int64 = 0
    @State private var feedback: String?
    @State private var showRestartConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                if let feedback {
                    Section {
                        Text(feedback)
                            .font(.system(size: 11))
                            .foregroundStyle(PitHubPalette.accent)
                    }
                }

                serviceSection
                passwordSection
                tunnelSection
                backgroundSection
                filePitSection
                photoSection
                clipSection
                dashSection
                cacheSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(PitHubBackground())
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: syncFields)
            .alert("重启服务？", isPresented: $showRestartConfirm) {
                Button("重启", role: .destructive) {
                    runtime.stop()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        runtime.start()
                        feedback = "服务已重启"
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("当前网页连接会短暂中断。")
            }
        }
    }

    // MARK: - 服务

    private var serviceSection: some View {
        Section {
            Stepper(value: settingBinding(\.port), in: 1024...65535) {
                LabeledContent("端口", value: "\(runtime.currentSettings.port)")
            }
            Stepper(value: settingBinding(\.sessionTimeoutMinutes), in: 5...43200, step: 5) {
                LabeledContent("会话超时", value: "\(runtime.currentSettings.sessionTimeoutMinutes) 分钟")
            }
            Toggle("允许访客只读登录", isOn: settingBinding(\.guestEnabled))
            Button("重启服务") { showRestartConfirm = true }
        } header: {
            Text("服务")
        } footer: {
            Text("修改端口会自动重启监听；当前局域网地址为 \(runtime.localURL.isEmpty ? "未启动" : runtime.localURL)。")
                .font(.system(size: 10))
        }
    }

    // MARK: - 密码

    private var passwordSection: some View {
        Section {
            if runtime.currentSettings.isDefaultPassword {
                Label("当前仍在使用默认密码 pithub，请尽快修改", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(PitHubPalette.warning)
            }
            SecureField("新的访问密码（普通用户）", text: $newAccessPassword)
            Button("更新访问密码") {
                guard newAccessPassword.count >= 4 else {
                    feedback = "访问密码至少需要 4 位"
                    return
                }
                runtime.settingsStore.setAccessPassword(newAccessPassword)
                newAccessPassword = ""
                feedback = "访问密码已更新"
            }
            SecureField("新的管理员密码（留空则与访问密码相同）", text: $newAdminPassword)
            Button("更新管理员密码") {
                guard newAdminPassword.count >= 4 else {
                    feedback = "管理员密码至少需要 4 位"
                    return
                }
                runtime.settingsStore.setAdminPassword(newAdminPassword)
                newAdminPassword = ""
                feedback = "管理员密码已更新"
            }
        } header: {
            Text("访问密码")
        } footer: {
            Text("网页、HTTP API、WebDAV 共用同一套密码与角色。WebDAV 用户名填 admin 表示管理员，其他用户名表示普通用户。")
                .font(.system(size: 10))
        }
    }

    // MARK: - 隧道

    private var tunnelSection: some View {
        Section {
            Toggle("开启外网隧道", isOn: settingBinding(\.tunnelEnabled))
            Picker("隧道方案", selection: settingBinding(\.tunnelProvider)) {
                ForEach(PitHubTunnelProvider.allCases, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            Stepper(value: settingBinding(\.wanRateLimitKBps), in: 0...102400, step: 64) {
                LabeledContent("外网限速", value: runtime.currentSettings.wanRateLimitKBps == 0 ? "不限速" : "\(runtime.currentSettings.wanRateLimitKBps) KB/s")
            }

            TextField("公网地址（Cloudflare / frp）", text: $tunnelPublicURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("保存公网地址") {
                runtime.updateSettings { $0.tunnelPublicURL = tunnelPublicURL.trimmed }
                feedback = "公网地址已保存"
            }

            TextField("Relay 地址（https://relay.example.com）", text: $relayURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            SecureField("Relay Token", text: $relayToken)
            Button("保存 Relay 配置") {
                runtime.updateSettings {
                    $0.relayURL = relayURL.trimmed
                    $0.relayToken = relayToken.trimmed
                }
                feedback = "Relay 配置已保存"
            }

            Button("复制 Cloudflare 命令") {
                UIPasteboard.general.string = PitHubTunnelManager.cloudflareCommand(port: currentPort)
                feedback = "已复制 cloudflared 命令"
            }
            Button("复制 frp 配置模板") {
                let ip = PitHubNetworkInfo.primaryIPv4() ?? "<iPhone IP>"
                UIPasteboard.general.string = PitHubTunnelManager.frpConfig(
                    serverAddress: "frp.example.com",
                    serverPort: 7000,
                    token: "替换成你的 token",
                    iphoneIP: ip,
                    localPort: currentPort
                )
                feedback = "已复制 frp 配置"
            }
        } header: {
            Text("外网隧道")
        } footer: {
            Text("iOS 沙盒禁止 App 启动 cloudflared/frpc 外部二进制。Cloudflare 与 frp 需要外部连接器；Relay 模式由 App 主动连出，可一键生成公网地址。隧道只转发流量，不存储数据。")
                .font(.system(size: 10))
        }
    }

    // MARK: - 后台

    private var backgroundSection: some View {
        Section {
            Picker("锁屏策略", selection: settingBinding(\.backgroundPolicy)) {
                ForEach(PitHubBackgroundPolicy.allCases, id: \.self) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
            Toggle("屏幕常亮（禁止自动锁屏）", isOn: settingBinding(\.preventAutoLock))
            Toggle("本地通知", isOn: settingBinding(\.notificationsEnabled))
        } header: {
            Text("后台与通知")
        } footer: {
            Text("iOS 不允许普通 App 常驻后台。锁屏后 App 仍可能被系统挂起；建议插电常驻并保持屏幕常亮。不要使用私有 API 强行保活，那会导致 TestFlight 审核失败。")
                .font(.system(size: 10))
        }
    }

    // MARK: - FilePit

    private var filePitSection: some View {
        Section {
            Stepper(value: settingBinding(\.filePit.maxUploadMB), in: 1...65536, step: 100) {
                LabeledContent("上传上限", value: "\(runtime.currentSettings.filePit.maxUploadMB) MB")
            }
            Stepper(value: settingBinding(\.filePit.shareExpiryMinutes), in: 1...10080, step: 10) {
                LabeledContent("分享默认有效期", value: "\(runtime.currentSettings.filePit.shareExpiryMinutes) 分钟")
            }
            Stepper(value: settingBinding(\.filePit.chunkMB), in: 1...64) {
                LabeledContent("分片大小", value: "\(runtime.currentSettings.filePit.chunkMB) MB")
            }
            Toggle("允许 ZIP 打包下载", isOn: settingBinding(\.filePit.allowZipDownload))
            Toggle("挂载系统相册到 /photos", isOn: settingBinding(\.filePit.allowPhotoMount))

            TextField("禁止上传的扩展名，逗号分隔", text: $blockedExtensions)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("保存扩展名黑名单") {
                let list = blockedExtensions.split(separator: ",")
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .")).lowercased() }
                    .filter { !$0.isEmpty }
                runtime.updateSettings { $0.filePit.blockedExtensions = list }
                feedback = "扩展名黑名单已保存"
            }
        } header: {
            Text("FilePit")
        } footer: {
            Text("分享链接形如 \(runtime.shareBaseURL)/s/<token>，支持到期时间与可选密码。访客只读，私有目录仅管理员。")
                .font(.system(size: 10))
        }
    }

    // MARK: - PhotoNode

    private var photoSection: some View {
        Section {
            Toggle("共享视频", isOn: settingBinding(\.photoNode.includeVideos))
            Toggle("包含隐藏照片", isOn: settingBinding(\.photoNode.includeHiddenAssets))
            Stepper(value: settingBinding(\.photoNode.thumbnailQuality), in: 30...100, step: 5) {
                LabeledContent("缩略图质量", value: "\(runtime.currentSettings.photoNode.thumbnailQuality)%")
            }
            NavigationLink {
                AlbumPickerView()
            } label: {
                LabeledContent("允许共享的相册", value: allowedAlbumSummary)
            }
        } header: {
            Text("PhotoNode")
        } footer: {
            Text("相册只读。选择“全部相册”时允许浏览所有照片；指定相册后，PhotoNode 与 FilePit 的 /photos 都会遵守同一白名单。")
                .font(.system(size: 10))
        }
    }

    // MARK: - ClipHub / DashLink

    private var clipSection: some View {
        Section {
            Stepper(value: settingBinding(\.clipHub.maxRecords), in: 10...5000, step: 10) {
                LabeledContent("最大记录数", value: "\(runtime.currentSettings.clipHub.maxRecords)")
            }
            Stepper(value: settingBinding(\.clipHub.maxItemMB), in: 1...64) {
                LabeledContent("单条上限", value: "\(runtime.currentSettings.clipHub.maxItemMB) MB")
            }
            Stepper(value: settingBinding(\.clipHub.retentionDays), in: 1...3650, step: 1) {
                LabeledContent("保留天数", value: "\(runtime.currentSettings.clipHub.retentionDays) 天")
            }
        } header: {
            Text("ClipHub")
        }
    }

    private var dashSection: some View {
        Section {
            Stepper(value: settingBinding(\.dashLink.cooldownSeconds), in: 0...3600, step: 5) {
                LabeledContent("默认冷却", value: "\(runtime.currentSettings.dashLink.cooldownSeconds) 秒")
            }
            Stepper(value: settingBinding(\.dashLink.maxRuns), in: 10...5000, step: 10) {
                LabeledContent("执行记录上限", value: "\(runtime.currentSettings.dashLink.maxRuns)")
            }
        } header: {
            Text("DashLink")
        } footer: {
            Text("冷却用于防止按钮被频繁触发；每个按钮也可以单独设置冷却时间。执行结果需要快捷指令主动回调。")
                .font(.system(size: 10))
        }
    }

    // MARK: - 缓存与关于

    private var cacheSection: some View {
        Section {
            LabeledContent("共享缓存", value: PitHubFormat.humanBytes(runtime.cache.totalBytes))
            LabeledContent("缩略图缓存", value: PitHubFormat.humanBytes(runtime.thumbnailCache.totalBytes))
            Button("清空缓存", role: .destructive) {
                runtime.cache.clear()
                runtime.thumbnailCache.clear()
                cacheBytes = 0
                feedback = "缓存已清空"
            }
        } header: {
            Text("缓存")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("版本", value: "PitHub 1.1.0")
            LabeledContent("WebDAV", value: "\(runtime.shareBaseURL)/webdav")
            LabeledContent("默认密码", value: "pithub")
            Button("打开网页控制台") {
                if let url = URL(string: runtime.localURL.isEmpty ? runtime.shareBaseURL : runtime.localURL) {
                    UIApplication.shared.open(url)
                }
            }
            Button("复制局域网地址") {
                UIPasteboard.general.string = runtime.localURL
                feedback = "已复制"
            }
        } header: {
            Text("关于")
        } footer: {
            Text("所有照片、文件、剪贴内容都保存在这台 iPhone 上；隧道只做流量转发，不存储任何数据。")
                .font(.system(size: 10))
        }
    }

    // MARK: - 工具

    private var currentPort: UInt16 {
        let port = runtime.port
        if port != 0 { return port }
        return UInt16(clamping: max(1, min(65535, runtime.currentSettings.port)))
    }

    private var allowedAlbumSummary: String {
        let ids = runtime.currentSettings.photoNode.allowedAlbumIDs
        return ids.isEmpty ? "全部相册" : "\(ids.count) 个相册"
    }

    private func settingBinding<T>(_ keyPath: WritableKeyPath<PitHubSettings, T>) -> Binding<T> {
        Binding(
            get: { runtime.currentSettings[keyPath: keyPath] },
            set: { newValue in
                runtime.updateSettings { settings in
                    settings[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func syncFields() {
        let settings = runtime.currentSettings
        tunnelPublicURL = settings.tunnelPublicURL
        relayURL = settings.relayURL
        relayToken = settings.relayToken
        blockedExtensions = settings.filePit.blockedExtensions.joined(separator: ", ")
        cacheBytes = runtime.cache.totalBytes + runtime.thumbnailCache.totalBytes
    }
}

// MARK: - 相册白名单

struct AlbumPickerView: View {
    @EnvironmentObject private var runtime: PitHubRuntime
    @Environment(\.dismiss) private var dismiss

    @State private var albums: [PitHubPhotoAlbum] = []
    @State private var selected: Set<String> = []
    @State private var allowAll = true
    @State private var authorized = false
    @State private var message: String?

    var body: some View {
        List {
            Section {
                Toggle("共享全部相册", isOn: $allowAll)
                    .onChange(of: allowAll) { value in
                        if value { selected.removeAll() }
                    }
            } footer: {
                Text("关闭后，只有勾选的相册会被 PhotoNode 与 /photos 暴露。")
                    .font(.system(size: 10))
            }

            if !authorized {
                Section {
                    Button("授权访问相册") {
                        PitHubPhotoLibrary.shared.requestAccess { _ in
                            DispatchQueue.main.async {
                                authorized = PitHubPhotoLibrary.shared.isAuthorized
                                if authorized { loadAlbums() }
                            }
                        }
                    }
                }
            } else {
                Section {
                    ForEach(albums) { album in
                        Button {
                            guard !allowAll else { return }
                            if selected.contains(album.id) {
                                selected.remove(album.id)
                            } else {
                                selected.insert(album.id)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.title)
                                        .font(.system(size: 13))
                                    Text("\(album.count) 项")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if allowAll || selected.contains(album.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(PitHubPalette.accent)
                                } else {
                                    Image(systemName: "circle")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("相册")
                }
            }

            if let message {
                Section {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(PitHubPalette.warning)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(PitHubBackground())
        .navigationTitle("允许共享的相册")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("保存") { save() }
            }
        }
        .onAppear {
            authorized = PitHubPhotoLibrary.shared.isAuthorized
            let ids = runtime.currentSettings.photoNode.allowedAlbumIDs
            allowAll = ids.isEmpty
            selected = Set(ids)
            if authorized { loadAlbums() }
        }
    }

    private func loadAlbums() {
        DispatchQueue.global(qos: .userInitiated).async {
            let list = PitHubPhotoLibrary.shared.albums(allowedIDs: [])
                .filter { $0.id != "all" }
            DispatchQueue.main.async { albums = list }
        }
    }

    private func save() {
        if !allowAll && selected.isEmpty {
            message = "至少选择一个相册，或开启“共享全部相册”。"
            return
        }
        runtime.updateSettings { settings in
            settings.photoNode.allowedAlbumIDs = allowAll ? [] : Array(selected).sorted()
        }
        dismiss()
    }
}
