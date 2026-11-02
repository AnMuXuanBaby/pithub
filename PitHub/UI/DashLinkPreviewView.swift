//
//  DashLinkPreviewView.swift
//  PitHub
//

import SwiftUI
import PitHubCore
import PitHubDashLink

struct DashLinkPreviewView: View {
    let plugin: DashLinkPlugin

    @State private var buttons: [DashButton] = []
    @State private var runs: [DashRun] = []
    @State private var alertMessage: String?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if buttons.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("还没有按钮")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(PitHubPalette.textPrimary)
                        Text("打开网页控制台的 DashLink 面板，添加按钮并绑定快捷指令名称。iOS 没有公开 API 枚举快捷指令，名称需要手动填写。")
                            .font(.system(size: 12))
                            .foregroundStyle(PitHubPalette.textSecondary)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard()
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(buttons) { button in
                            Button {
                                execute(button)
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Image(systemName: button.icon.isEmpty ? "bolt.fill" : button.icon)
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundStyle(Color(hex: button.color) ?? PitHubPalette.accent)
                                    Text(button.title)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(PitHubPalette.textPrimary)
                                        .lineLimit(2)
                                    Text(button.shortcutName)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(PitHubPalette.textSecondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                                .background {
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(Color.white.opacity(0.05))
                                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(Color.white.opacity(0.09), lineWidth: 1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !runs.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("执行记录")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(PitHubPalette.textPrimary)
                        ForEach(runs) { run in
                            HStack(alignment: .top, spacing: 10) {
                                Circle()
                                    .fill(statusColor(run.status))
                                    .frame(width: 6, height: 6)
                                    .padding(.top, 5)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(run.buttonTitle)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(PitHubPalette.textPrimary)
                                    Text(run.message)
                                        .font(.system(size: 10))
                                        .foregroundStyle(PitHubPalette.textSecondary)
                                    if !run.result.isEmpty {
                                        Text(run.result)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(PitHubPalette.textSecondary)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer()
                                Text(PitHubFormat.fileDate(run.createdAt))
                                    .font(.system(size: 9))
                                    .foregroundStyle(PitHubPalette.textSecondary)
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard()
                }

                Text("通过 URL Scheme 调用快捷指令后，系统不会把结果回传给 App。可在快捷指令末尾用「获取 URL 内容」把结果 POST 到运行记录里的 callbackURL。")
                    .font(.system(size: 11))
                    .foregroundStyle(PitHubPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .background(PitHubBackground())
        .navigationTitle("DashLink")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .onAppear(perform: refresh)
        .alert("提示", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("好", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "completed": return PitHubPalette.success
        case "failed": return PitHubPalette.danger
        default: return PitHubPalette.warning
        }
    }

    private func execute(_ button: DashButton) {
        guard let run = plugin.nativeRun(buttonID: button.id) else {
            alertMessage = "冷却中，或快捷指令名称无效。"
            return
        }
        alertMessage = "已请求调用「\(run.shortcutName)」。结果需要快捷指令主动回调。"
        refresh()
    }

    private func refresh() {
        buttons = plugin.nativeButtons()
        runs = plugin.nativeRuns(limit: 20)
    }
}

extension Color {
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 8, let number = UInt64(value, radix: 16) else {
            return nil
        }
        if value.count == 6 {
            let red = Double((number >> 16) & 0xFF) / 255
            let green = Double((number >> 8) & 0xFF) / 255
            let blue = Double(number & 0xFF) / 255
            self.init(red: red, green: green, blue: blue)
        } else {
            let red = Double((number >> 24) & 0xFF) / 255
            let green = Double((number >> 16) & 0xFF) / 255
            let blue = Double((number >> 8) & 0xFF) / 255
            let alpha = Double(number & 0xFF) / 255
            self.init(red: red, green: green, blue: blue, opacity: alpha)
        }
    }
}
