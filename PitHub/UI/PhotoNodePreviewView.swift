//
//  PhotoNodePreviewView.swift
//  PitHub
//
//  App 内相册预览：相册分组 + 缩略图网格 + 大图查看。
//

import SwiftUI
import UIKit
import PitHubCore

struct PhotoNodePreviewView: View {
    @State private var albums: [PitHubPhotoAlbum] = []
    @State private var assets: [PitHubPhotoAsset] = []
    @State private var selectedAlbum = "all"
    @State private var total = 0
    @State private var offset = 0
    @State private var loading = false
    @State private var authorized = false
    @State private var errorMessage: String?
    @State private var detailAsset: PitHubPhotoAsset?

    private let pageSize = 120
    private let gridColumns = [GridItem(.adaptive(minimum: 96), spacing: 2)]

    private var library: PitHubPhotoLibrary { PitHubPhotoLibrary.shared }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if !authorized {
                    permissionCard
                } else {
                    albumBar
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(PitHubPalette.warning)
                            .padding(.horizontal, 16)
                    }
                    photoGrid
                    if assets.count < total {
                        Button {
                            loadAssets(reset: false)
                        } label: {
                            HStack(spacing: 6) {
                                if loading { ProgressView().tint(PitHubPalette.accent) }
                                Text(loading ? "加载中…" : "加载更多")
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                        .disabled(loading)
                    }
                }
            }
            .padding(.vertical, 12)
            .padding(.bottom, 24)
        }
        .background(PitHubBackground())
        .navigationTitle("PhotoNode")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    loadAlbums()
                    loadAssets(reset: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .onAppear(perform: prepare)
        .sheet(item: $detailAsset) { asset in
            PhotoAssetDetailView(asset: asset)
        }
    }

    private var permissionCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 34))
                .foregroundStyle(PitHubPalette.accent)
            Text("需要相册权限")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(PitHubPalette.textPrimary)
            Text("PhotoNode 只读取本机相册，不会上传照片。")
                .font(.system(size: 12))
                .foregroundStyle(PitHubPalette.textSecondary)
            Button("授权访问相册") {
                library.requestAccess { _ in
                    DispatchQueue.main.async {
                        authorized = library.isAuthorized
                        if authorized { loadAlbums(); loadAssets(reset: true) }
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(PitHubPalette.accent)
            if let url = URL(string: UIApplication.openSettingsURLString) {
                Button("打开系统设置") { UIApplication.shared.open(url) }
                    .font(.system(size: 12))
                    .foregroundStyle(PitHubPalette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .glassCard()
        .padding(.horizontal, 16)
    }

    private var albumBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(albums) { album in
                    Button {
                        selectedAlbum = album.id
                        loadAssets(reset: true)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(album.title)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            Text("\(album.count)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(PitHubPalette.textSecondary)
                        }
                        .foregroundStyle(selectedAlbum == album.id ? Color.white : PitHubPalette.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            selectedAlbum == album.id ? PitHubPalette.accent.opacity(0.8) : Color.white.opacity(0.055),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var photoGrid: some View {
        LazyVGrid(columns: gridColumns, spacing: 2) {
            ForEach(assets) { asset in
                Button {
                    detailAsset = asset
                } label: {
                    PhotoThumbnailCell(asset: asset)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 2)
    }

    private func prepare() {
        authorized = library.isAuthorized
        guard authorized else {
            library.requestAccess { _ in
                DispatchQueue.main.async {
                    authorized = library.isAuthorized
                    if authorized { loadAlbums(); loadAssets(reset: true) }
                }
            }
            return
        }
        loadAlbums()
        loadAssets(reset: true)
    }

    private func loadAlbums() {
        guard library.isAuthorized else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let list = library.albums(allowedIDs: [])
            DispatchQueue.main.async {
                albums = list
                if !list.contains(where: { $0.id == selectedAlbum }) {
                    selectedAlbum = list.first?.id ?? "all"
                }
            }
        }
    }

    private func loadAssets(reset: Bool) {
        guard library.isAuthorized, !loading else { return }
        loading = true
        let albumID = selectedAlbum
        let currentOffset = reset ? 0 : offset
        DispatchQueue.global(qos: .userInitiated).async {
            let result = library.assets(
                albumID: albumID,
                allowedAlbumIDs: [],
                includeVideos: true,
                includeHidden: false,
                year: nil,
                month: nil,
                offset: currentOffset,
                limit: pageSize
            )
            DispatchQueue.main.async {
                total = result.total
                if reset {
                    assets = result.items
                } else {
                    assets.append(contentsOf: result.items)
                }
                offset = assets.count
                loading = false
                errorMessage = result.items.isEmpty && result.total == 0 ? "这个相册暂时没有照片" : nil
            }
        }
    }
}

private struct PhotoThumbnailCell: View {
    let asset: PitHubPhotoAsset
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.white.opacity(0.04)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView().tint(PitHubPalette.textSecondary)
            }
            VStack {
                HStack {
                    if asset.isLivePhoto {
                        Text("LIVE")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.55), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    Spacer()
                }
                Spacer()
                HStack {
                    Spacer()
                    if asset.mediaType == "video" {
                        Label(durationText, systemImage: "play.fill")
                            .font(.system(size: 8, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.55), in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
            }
            .padding(5)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .onAppear(perform: load)
    }

    private var durationText: String {
        let seconds = Int(asset.duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func load() {
        guard image == nil else { return }
        PitHubPhotoLibrary.shared.thumbnailData(identifier: asset.id, maxPixel: 260, quality: 0.7) { data in
            guard let data, let loaded = UIImage(data: data) else { return }
            DispatchQueue.main.async { image = loaded }
        }
    }
}

private struct PhotoAssetDetailView: View {
    let asset: PitHubPhotoAsset
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .ignoresSafeArea(edges: .bottom)
                } else if loading {
                    ProgressView().tint(.white)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                        Text("无法加载这张照片")
                            .font(.system(size: 13))
                    }
                    .foregroundStyle(.white.opacity(0.7))
                }
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(asset.filename)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text("\(asset.pixelWidth) × \(asset.pixelHeight) · \(PitHubFormat.iso(asset.createdAt))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .foregroundStyle(.white)
                .padding(14)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(16)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        let maxPixel: CGFloat = asset.mediaType == "video" ? 1200 : 2048
        PitHubPhotoLibrary.shared.previewData(identifier: asset.id, maxPixel: maxPixel, quality: 0.86) { data in
            DispatchQueue.main.async {
                loading = false
                if let data { image = UIImage(data: data) }
            }
        }
    }
}
