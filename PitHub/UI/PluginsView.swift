//
//  PluginsView.swift
//  PitHub
//

import SwiftUI
import PitHubCore

struct PluginsView: View {
    let services: AppServices
    @EnvironmentObject private var runtime: PitHubRuntime

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(runtime.pluginDescriptors) { descriptor in
                        pluginCard(descriptor)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("插件架构")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(PitHubPalette.textSecondary)
                        Text("公共底层（HTTP / 鉴权 / WebDAV / 隧道 / 缓存 / 日志 / 流量）由 PitHubCore 提供，每个插件是独立 framework target，启用后自动挂载自己的路由前缀。")
                            .font(.system(size: 11))
                            .foregroundStyle(PitHubPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .padding(16)
            }
            .background(PitHubBackground())
            .navigationTitle("插件")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func pluginCard(_ descriptor: PitHubPluginDescriptor) -> some View {
        VStack(spacing: 0) {
            NavigationLink {
                destination(for: descriptor.id)
            } label: {
                pluginHeader(descriptor)
            }
            .buttonStyle(.plain)

            Divider().overlay(Color.white.opacity(0.08)).padding(.horizontal, 16)

            pluginToggleRow(descriptor)
        }
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        }
    }

    private func pluginHeader(_ descriptor: PitHubPluginDescriptor) -> some View {
        HStack(spacing: 14) {
            pluginIcon(descriptor)
            pluginInfo(descriptor)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PitHubPalette.textSecondary.opacity(0.6))
        }
        .padding(16)
    }

    private func pluginIcon(_ descriptor: PitHubPluginDescriptor) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(PitHubPalette.accent.opacity(0.14))
                .frame(width: 46, height: 46)
            Image(systemName: descriptor.icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(PitHubPalette.accent)
        }
    }

    private func pluginInfo(_ descriptor: PitHubPluginDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            pluginTitle(descriptor)
            Text(descriptor.summary)
                .font(.system(size: 11))
                .foregroundStyle(PitHubPalette.textSecondary)
                .lineLimit(2)
            Text(descriptor.prefix)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(PitHubPalette.accent.opacity(0.8))
        }
    }

    private func pluginTitle(_ descriptor: PitHubPluginDescriptor) -> some View {
        HStack(spacing: 8) {
            Text(descriptor.name)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(PitHubPalette.textPrimary)
            if descriptor.id == "file" {
                PillLabel(text: "主力", color: PitHubPalette.accent)
            }
            if !descriptor.enabled {
                PillLabel(text: "已禁用", color: PitHubPalette.textSecondary)
            }
        }
    }

    private func pluginToggleRow(_ descriptor: PitHubPluginDescriptor) -> some View {
        HStack {
            Text("启用该插件")
                .font(.system(size: 12))
                .foregroundStyle(PitHubPalette.textSecondary)
            Spacer()
            Toggle("", isOn: pluginBinding(descriptor))
                .labelsHidden()
                .tint(PitHubPalette.accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func pluginBinding(_ descriptor: PitHubPluginDescriptor) -> Binding<Bool> {
        Binding(
            get: {
                runtime.currentSettings.pluginEnabled[descriptor.id] ?? descriptor.defaultEnabled
            },
            set: { value in
                runtime.setPluginEnabled(id: descriptor.id, enabled: value)
            }
        )
    }

    @ViewBuilder
    private func destination(for id: String) -> some View {
        switch id {
        case "file":
            FilePitPreviewView(plugin: services.filePit)
        case "photo":
            PhotoNodePreviewView()
        case "clip":
            ClipHubPreviewView(plugin: services.clipHub)
        case "dash":
            DashLinkPreviewView(plugin: services.dashLink)
        default:
            Text("该插件暂未提供本机预览")
                .foregroundStyle(PitHubPalette.textSecondary)
        }
    }
}
