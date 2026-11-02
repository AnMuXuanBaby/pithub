//
//  FilePitPreviewView.swift
//  PitHub
//
//  App 内直接浏览 FilePit 目录，并用 QuickLook 预览本地文件。
//

import SwiftUI
import QuickLook
import PitHubCore
import PitHubFilePit

struct FilePitPreviewView: View {
    let plugin: FilePitPlugin

    @State private var path = "/"
    @State private var entries: [FilePitEntry] = []
    @State private var errorMessage: String?
    @State private var alertMessage: String?
    @State private var previewURL: URL?
    @State private var showPreview = false

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(PitHubPalette.warning)
                }
            }

            Section {
                ForEach(entries) { entry in
                    Button {
                        open(entry)
                    } label: {
                        row(entry)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                HStack {
                    Text(currentTitle)
                    Spacer()
                    Text("\(entries.count) 项")
                }
                .font(.system(size: 11))
                .foregroundStyle(PitHubPalette.textSecondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(PitHubBackground())
        .navigationTitle(currentTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    load()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            ToolbarItem(placement: .navigationBarLeading) {
                if path != "/" {
                    Button("上一级") { goUp() }
                }
            }
        }
        .refreshable { load() }
        .onAppear(perform: load)
        .sheet(isPresented: $showPreview) {
            if let previewURL {
                QuickLookView(url: previewURL)
                    .ignoresSafeArea()
            }
        }
        .alert("提示", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("好", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var currentTitle: String {
        if path == "/" { return "FilePit" }
        return (path as NSString).lastPathComponent
    }

    private func row(_ entry: FilePitEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: entry))
                .font(.system(size: 18))
                .foregroundStyle(entry.isDirectory ? PitHubPalette.accent : PitHubPalette.textSecondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(PitHubPalette.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if entry.isDirectory {
                        if entry.assetCount > 0 { Text("\(entry.assetCount) 项") }
                        else { Text("文件夹") }
                    } else {
                        Text(PitHubFormat.humanBytes(entry.size))
                    }
                    if entry.isReadOnly {
                        Text("只读")
                    }
                    if entry.rootID == "photos" {
                        Text("相册")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(PitHubPalette.textSecondary)
            }
            Spacer()
            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PitHubPalette.textSecondary.opacity(0.5))
            }
        }
        .contentShape(Rectangle())
    }

    private func icon(for entry: FilePitEntry) -> String {
        if entry.isDirectory { return entry.rootID == "photos" ? "photo.stack" : "folder.fill" }
        switch entry.kind {
        case "image": return "photo"
        case "video": return "film"
        case "pdf": return "doc.richtext"
        case "text": return "doc.text"
        case "audio": return "waveform"
        default: return "doc"
        }
    }

    private func open(_ entry: FilePitEntry) {
        if entry.isDirectory {
            path = entry.path
            load()
            return
        }
        guard let url = plugin.nativeFileURL(path: entry.path) else {
            alertMessage = "该文件（例如相册挂载中的照片）需要先导出，或该目录仅管理员可访问。"
            return
        }
        previewURL = url
        showPreview = true
    }

    private func goUp() {
        let components = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .components(separatedBy: "/")
        guard components.count > 1 else {
            path = "/"
            load()
            return
        }
        path = "/" + components.dropLast().joined(separator: "/")
        load()
    }

    private func load() {
        do {
            entries = try plugin.nativeList(path: path)
            errorMessage = nil
        } catch {
            entries = []
            errorMessage = error.localizedDescription
        }
    }
}

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
