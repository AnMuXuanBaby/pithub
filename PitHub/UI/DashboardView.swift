//
//  DashboardView.swift
//  PitHub
//

import SwiftUI
import UIKit
import Photos
import UserNotifications
import PitHubCore

struct DashboardView: View {
    @EnvironmentObject private var runtime: PitHubRuntime

    @State private var qrMode = 0
    @State private var qrImage: UIImage?
    @State private var photoAuthorized = false
    @State private var notificationAuthorized = false
    @State private var permissionMessage: String?

    private var activeURL: String {
        if qrMode == 1 {
            return runtime.tunnelStatus.publicURL ?? ""
        }
        return runtime.localURL
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                serviceCard
                statusGrid
                qrCard
                tunnelCard
                permissionCard
                backgroundCard
            }
            .padding(16)
            .padding(.bottom, 12)
        }
        .background(PitHubBackground())
        .scrollIndicators(.hidden)
        .onAppear(perform: refreshAll)
        .onChange(of: runtime.localURL) { _ in refreshQR() }
        .onChange(of: runtime.tunnelStatus) { _ in refreshQR() }
        .onChange(of: qrMode) { _ in refreshQR() }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 9) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(PitHubPalette.accent)
                    Text("PitHub")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(PitHubPalette.textPrimary)
                }
                Text("家庭私有微型服务器 · 插件式超级网关")
                    .font(.system(size: 12))
                    .foregroundStyle(PitHubPalette.textSecondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 6) {
                    StatusDot(active: runtime.isRunning)
                    Text(runtime.isRunning ? "在线" : "离线")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(runtime.isRunning ? PitHubPalette.success : PitHubPalette.textSecondary)
                }
                if runtime.isRunning {
                    Text("端口 \(String(runtime.port))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(PitHubPalette.textSecondary)
                }
            }
        }
        .padding(.top, 8)
    }

    // MARK: - 服务开关

    private var serviceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(runtime.isRunning ? PitHubPalette.accent.opacity(0.18) : Color.white.opacity(0.06))
                        .frame(width: 52, height: 52)
                    Image(systemName: runtime.isRunning ? "antenna.radiowaves.left.and.right" : "power")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(runtime.isRunning ? PitHubPalette.accent : PitHubPalette.textSecondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(runtime.isRunning ? "服务运行中" : "服务已停止")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(PitHubPalette.textPrimary)
                    Text(runtime.isRunning ? (runtime.localURL.isEmpty ? "正在获取局域网地址…" : runtime.localURL) : "点击右侧按钮启动 HTTP 服务")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(PitHubPalette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    runtime.toggle()
                } label: {
                    Image(systemName: runtime.isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(
                            (runtime.isRunning ? PitHubPalette.danger : PitHubPalette.accent).opacity(0.9),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
            }

            if let error = runtime.lastError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(PitHubPalette.danger)
            }

            Divider().overlay(Color.white.opacity(0.08))

            HStack(spacing: 10) {
                Label("Bonjour: _pithub._tcp", systemImage: "dot.radiowaves.left.and.right")
                    .font(.system(size: 11))
                    .foregroundStyle(PitHubPalette.textSecondary)
                Spacer()
                if runtime.isRunning {
                    Text("运行 \(uptimeText)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(PitHubPalette.textSecondary)
                }
            }
        }
        .glassCard()
    }

    // MARK: - 状态网格

    private var statusGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            StatusTile(
                title: "局域网地址",
                value: runtime.localURL.isEmpty ? "未启动" : runtime.localURL,
                icon: "wifi",
                accent: PitHubPalette.accent,
                copyable: true
            )
            StatusTile(
                title: "公网隧道",
                value: runtime.tunnelStatus.active ? (runtime.tunnelStatus.publicURL ?? "-") : runtime.tunnelStatus.message,
                icon: "globe.asia.australia.fill",
                accent: runtime.tunnelStatus.active ? PitHubPalette.success : PitHubPalette.textSecondary,
                copyable: runtime.tunnelStatus.active
            )
            StatusTile(
                title: "当前连接",
                value: "\(runtime.activeConnections)",
                icon: "link",
                accent: PitHubPalette.accent
            )
            StatusTile(
                title: "总流量",
                value: PitHubFormat.humanBytes(runtime.traffic.totalBytes),
                icon: "arrow.up.arrow.down",
                accent: PitHubPalette.accent
            )
            StatusTile(
                title: "局域网流量",
                value: PitHubFormat.humanBytes(runtime.traffic.lanBytesIn + runtime.traffic.lanBytesOut),
                icon: "house.fill",
                accent: PitHubPalette.textSecondary
            )
            StatusTile(
                title: "隧道流量",
                value: PitHubFormat.humanBytes(runtime.traffic.tunnelBytesIn + runtime.traffic.tunnelBytesOut),
                icon: "cloud.fill",
                accent: PitHubPalette.textSecondary
            )
        }
    }

    // MARK: - 二维码

    private var qrCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionTitle(title: "扫码访问", subtitle: "同一 Wi-Fi 或公网地址")
                Spacer()
                Picker("", selection: $qrMode) {
                    Text("局域网").tag(0)
                    Text("公网").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .disabled(runtime.tunnelStatus.publicURL == nil)
            }

            HStack(spacing: 16) {
                Group {
                    if let qrImage {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 150, height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                            .frame(width: 150, height: 150)
                            .overlay {
                                Text("服务启动后生成")
                                    .font(.system(size: 12))
                                    .foregroundStyle(PitHubPalette.textSecondary)
                            }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(qrMode == 1 ? "公网访问" : "局域网访问")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PitHubPalette.textPrimary)
                    MonospaceURL(text: activeURL.isEmpty ? "—" : activeURL)
                    if !activeURL.isEmpty {
                        HStack(spacing: 10) {
                            Button("复制链接") {
                                UIPasteboard.general.string = activeURL
                            }
                            .font(.system(size: 12, weight: .semibold))
                            Button("刷新") { refreshQR() }
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(PitHubPalette.accent)
                    }
                    Text("用手机相机扫描，或直接输入地址。WebDAV 地址为 /webdav。")
                        .font(.system(size: 11))
                        .foregroundStyle(PitHubPalette.textSecondary)
                }
                Spacer()
            }
        }
        .glassCard()
    }

    // MARK: - 隧道

    private var tunnelCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionTitle(title: "外网穿透", subtitle: runtime.tunnelStatus.provider.displayName)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { runtime.currentSettings.tunnelEnabled },
                    set: { value in runtime.updateSettings { $0.tunnelEnabled = value } }
                ))
                .labelsHidden()
                .tint(PitHubPalette.accent)
            }

            HStack(spacing: 8) {
                StatusDot(active: runtime.tunnelStatus.active)
                Text(runtime.tunnelStatus.message)
                    .font(.system(size: 12))
                    .foregroundStyle(runtime.tunnelStatus.active ? PitHubPalette.success : PitHubPalette.textSecondary)
            }

            if let url = runtime.tunnelStatus.publicURL, runtime.tunnelStatus.active {
                HStack {
                    MonospaceURL(text: url)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = url
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PitHubPalette.textSecondary)
                }
            }

            Text(tunnelHint)
                .font(.system(size: 11))
                .foregroundStyle(PitHubPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .glassCard()
    }

    private var tunnelHint: String {
        switch runtime.currentSettings.tunnelProvider {
        case .cloudflare:
            return "Cloudflare Tunnel 需要在电脑/路由器上运行 cloudflared 指向本机端口（iOS 沙盒不允许 App 启动外部二进制）。在「设置 → 外网隧道」可复制完整命令。"
        case .relay:
            return "Relay 模式由 App 主动连出去，无需公网 IP。需要先部署仓库中的 relay/server.mjs，并在设置里填写地址与 Token。"
        case .frp:
            return "frp 模式同样需要外部 frpc 客户端；在设置里可复制配置模板。"
        case .none:
            return "当前为仅局域网模式。"
        }
    }

    // MARK: - 权限

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "权限", subtitle: "相册、通知与本地网络")

            PermissionRow(
                title: "相册读取",
                detail: photoAuthorized ? "已授权" : "PhotoNode 与相册挂载需要",
                granted: photoAuthorized
            ) {
                if !photoAuthorized {
                    PitHubPhotoLibrary.shared.requestAccess { status in
                        DispatchQueue.main.async {
                            photoAuthorized = status == .authorized || status == .limited
                            permissionMessage = photoAuthorized ? nil : "相册权限被拒绝，请在系统设置中开启。"
                        }
                    }
                } else if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }

            PermissionRow(
                title: "本地通知",
                detail: notificationAuthorized ? "已授权" : "上传完成、隧道断开时提醒",
                granted: notificationAuthorized
            ) {
                if !notificationAuthorized {
                    PitHubNotifier.shared.requestAuthorization { granted in
                        DispatchQueue.main.async { notificationAuthorized = granted }
                    }
                } else if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }

            PermissionRow(
                title: "本地网络",
                detail: "首次启动服务时系统会弹窗，请允许",
                granted: runtime.isRunning
            ) {}

            if let permissionMessage {
                Text(permissionMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(PitHubPalette.warning)
            }
        }
        .glassCard()
    }

    // MARK: - 后台说明

    private var backgroundCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(PitHubPalette.warning)
                Text("关于 iOS 后台限制")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PitHubPalette.textPrimary)
            }
            Text("iOS 会在锁屏或切到后台一段时间后挂起 App，NWListener 也会随之暂停。这是系统机制，无法用公开 API 绕过。建议：插电常驻、保持屏幕常亮（App 已默认禁止自动锁屏）、把 PitHub 放在前台。需要长时间无人值守时，使用「锁屏尽量保活」并接受可能仍被系统回收。")
                .font(.system(size: 12))
                .foregroundStyle(PitHubPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .glassCard()
    }

    // MARK: - 工具

    private var uptimeText: String {
        guard let startedAt = runtime.startedAt else { return "—" }
        let seconds = Int(Date().timeIntervalSince(startedAt))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private func refreshAll() {
        refreshQR()
        refreshPermissions()
    }

    private func refreshQR() {
        let url = activeURL
        qrImage = url.isEmpty ? nil : PitHubQRCode.styledImage(for: url, size: 300)
    }

    private func refreshPermissions() {
        photoAuthorized = PitHubPhotoLibrary.shared.isAuthorized
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                notificationAuthorized = settings.authorizationStatus == .authorized
            }
        }
    }
}

// MARK: - 组件

struct StatusTile: View {
    let title: String
    let value: String
    let icon: String
    var accent: Color = PitHubPalette.accent
    var copyable: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PitHubPalette.textSecondary)
                Spacer()
                if copyable {
                    Button {
                        UIPasteboard.general.string = value
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(PitHubPalette.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(PitHubPalette.textPrimary)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(granted ? PitHubPalette.success : PitHubPalette.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PitHubPalette.textPrimary)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(PitHubPalette.textSecondary)
            }
            Spacer()
            Button(granted ? "设置" : "授权", action: action)
                .font(.system(size: 12, weight: .semibold))
                .buttonStyle(.bordered)
                .tint(PitHubPalette.accent)
        }
    }
}
