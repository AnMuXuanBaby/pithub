//
//  ClipHubPreviewView.swift
//  PitHub
//

import SwiftUI
import UIKit
import PitHubCore
import PitHubClipHub

struct ClipHubPreviewView: View {
    let plugin: ClipHubPlugin

    @State private var items: [ClipItem] = []
    @State private var draft = ""
    @State private var message: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("输入要保存的剪贴内容…", text: $draft, axis: .vertical)
                        .lineLimit(2...6)
                        .textFieldStyle(.plain)
                        .foregroundStyle(PitHubPalette.textPrimary)
                    HStack {
                        Text("\(items.count) 条记录")
                            .font(.system(size: 11))
                            .foregroundStyle(PitHubPalette.textSecondary)
                        Spacer()
                        Button("保存") {
                            guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                            if plugin.nativePushText(draft) {
                                draft = ""
                                refresh()
                                message = "已保存到剪贴历史"
                            }
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .buttonStyle(.borderedProminent)
                        .tint(PitHubPalette.accent)
                    }
                    if let message {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(PitHubPalette.success)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                ForEach(items) { item in
                    Button {
                        if item.kind == "text" {
                            UIPasteboard.general.string = item.text
                            message = "已复制到系统剪贴板"
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: icon(for: item))
                                .font(.system(size: 16))
                                .foregroundStyle(PitHubPalette.accent)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.kind == "text" ? item.text : item.filename)
                                    .font(.system(size: 13))
                                    .foregroundStyle(PitHubPalette.textPrimary)
                                    .lineLimit(3)
                                HStack(spacing: 8) {
                                    Text(PitHubFormat.iso(item.createdAt))
                                    if !item.tags.isEmpty {
                                        Text(item.tags.map { "#\($0)" }.joined(separator: " "))
                                    }
                                    Text(PitHubFormat.humanBytes(item.size))
                                }
                                .font(.system(size: 10))
                                .foregroundStyle(PitHubPalette.textSecondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) {
                            plugin.nativeDelete(id: item.id)
                            refresh()
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("历史记录")
                    .font(.system(size: 11))
            }
        }
        .scrollContentBackground(.hidden)
        .background(PitHubBackground())
        .navigationTitle("ClipHub")
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
        .refreshable { refresh() }
        .onAppear(perform: refresh)
    }

    private func icon(for item: ClipItem) -> String {
        switch item.kind {
        case "image": return "photo"
        case "file": return "doc"
        default: return "text.alignleft"
        }
    }

    private func refresh() {
        items = plugin.nativeItems(limit: 100)
    }
}
