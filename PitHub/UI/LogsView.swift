//
//  LogsView.swift
//  PitHub
//

import SwiftUI
import UIKit
import PitHubCore

struct LogsView: View {
    @EnvironmentObject private var runtime: PitHubRuntime

    @State private var entries: [PitHubAccessLogEntry] = []
    @State private var total = 0
    @State private var offset = 0
    @State private var query = ""
    @State private var loading = false
    @State private var exportURL: URL?
    @State private var showShare = false
    @State private var showClearConfirm = false
    @State private var message: String?

    private let pageSize = 60

    var body: some View {
        NavigationStack {
            List {
                if let message {
                    Section {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(PitHubPalette.textSecondary)
                    }
                }

                Section {
                    ForEach(entries) { entry in
                        row(entry)
                    }
                    if entries.count < total {
                        Button {
                            load(reset: false)
                        } label: {
                            HStack {
                                Spacer()
                                if loading { ProgressView().tint(PitHubPalette.accent) }
                                Text(loading ? "加载中…" : "加载更多")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                        }
                        .disabled(loading)
                    }
                } header: {
                    HStack {
                        Text("共 \(total) 条")
                        Spacer()
                        Text("最新在前")
                    }
                    .font(.system(size: 10))
                }
            }
            .scrollContentBackground(.hidden)
            .background(PitHubBackground())
            .navigationTitle("访问日志")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索 IP / 路径 / 操作")
            .onChange(of: query) { _ in load(reset: true) }
            .refreshable { load(reset: true) }
            .onAppear { load(reset: true) }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("导出 JSON") { export(format: "json") }
                        Button("导出 TXT") { export(format: "txt") }
                        Divider()
                        Button("清空日志", role: .destructive) { showClearConfirm = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showShare) {
                if let exportURL {
                    ActivityView(items: [exportURL])
                        .ignoresSafeArea()
                }
            }
            .alert("清空访问日志？", isPresented: $showClearConfirm) {
                Button("清空", role: .destructive) {
                    runtime.logStore.clear()
                    load(reset: true)
                    message = "日志已清空"
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("此操作不可恢复。")
            }
        }
    }

    private func row(_ entry: PitHubAccessLogEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.method)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(PitHubPalette.accent)
                    Text(entry.action)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(PitHubPalette.textSecondary)
                    if entry.tunnel {
                        PillLabel(text: "隧道", color: PitHubPalette.warning)
                    }
                    if entry.status >= 400 {
                        PillLabel(text: "\(entry.status)", color: PitHubPalette.danger)
                    }
                }
                Text(entry.path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(PitHubPalette.textPrimary)
                    .lineLimit(2)
                HStack(spacing: 10) {
                    Text(entry.ip)
                    Text(entry.role)
                    Text(PitHubFormat.humanBytes(entry.bytesOut))
                }
                .font(.system(size: 9))
                .foregroundStyle(PitHubPalette.textSecondary)
            }
            Spacer()
            Text(PitHubFormat.fileDate(entry.date))
                .font(.system(size: 9))
                .foregroundStyle(PitHubPalette.textSecondary)
        }
        .padding(.vertical, 2)
    }

    private func load(reset: Bool) {
        guard !loading else { return }
        loading = true
        let currentOffset = reset ? 0 : offset
        DispatchQueue.global(qos: .userInitiated).async {
            let page = runtime.logStore.page(offset: currentOffset, limit: pageSize, query: query)
            DispatchQueue.main.async {
                total = page.total
                if reset {
                    entries = page.items
                } else {
                    entries.append(contentsOf: page.items)
                }
                offset = entries.count
                loading = false
            }
        }
    }

    private func export(format: String) {
        let data = format == "txt" ? runtime.logStore.exportText() : runtime.logStore.exportJSON()
        let name = "pithub-logs-\(Int(Date().timeIntervalSince1970)).\(format)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            exportURL = url
            showShare = true
        } catch {
            message = "导出失败：\(error.localizedDescription)"
        }
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
