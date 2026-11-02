//
//  PhotoNodePlugin.swift
//  PitHubPhotoNode
//
//  相册 NAS：只读访问系统相册（PhotoKit），提供相册分组、时间线、
//  缩略图、原图/视频下载。所有照片始终保存在本机。
//
//  沙盒限制：PHAsset 没有可直接读取的文件 URL，原图下载通过
//  PHAssetResourceManager 导出到临时目录后流式发送。
//

import Foundation
import Photos
import PitHubCore

public final class PhotoNodePlugin: PitHubPlugin {

    public var id: String { "photo" }
    public var displayName: String { "PhotoNode" }
    public var summary: String { "相册 NAS · 时间线 · 实况照片 · 原图/视频下载" }
    public var systemImage: String { "photo.on.rectangle.angled" }
    public var apiPrefix: String { "/api/photo" }
    public var extraPrefixes: [String] { [] }
    public var defaultEnabled: Bool { true }

    private weak var host: PitHubPluginHost?
    private let exportDirectory = PitHubPaths.root.appendingPathComponent("tmp/photo-exports", isDirectory: true)

    public init() {}

    public func attach(host: PitHubPluginHost, dataDirectory: URL) {
        self.host = host
        try? PitHubPaths.ensureDirectory(exportDirectory)
    }

    public func handle(_ request: HTTPRequest,
                       subPath: String,
                       context: PitHubPluginRequestContext,
                       respond: @escaping (HTTPResponse) -> Void) {
        guard let host else {
            respond(.error(503, "PhotoNode 尚未就绪"))
            return
        }
        let library = host.photoLibrary
        guard library.isAuthorized else {
            respond(.error(403, "尚未获得相册权限，请在 PitHub App 中授权"))
            return
        }

        var route = subPath
        if route.hasPrefix("/") { route.removeFirst() }
        if route.hasSuffix("/") { route.removeLast() }

        let settings = context.settings

        switch route {
        case "albums":
            respondAlbums(library: library, settings: settings, respond: respond)

        case "assets":
            respondAssets(request: request, library: library, settings: settings, respond: respond)

        case "timeline":
            let albumID = normalizedAlbumID(request.query["album"])
            let buckets = library.timeline(albumID: albumID, allowedAlbumIDs: settings.photoNode.allowedAlbumIDs)
            respond(.json([
                "ok": true,
                "buckets": buckets.map { ["year": $0.year, "month": $0.month, "count": $0.count] }
            ]))

        case "thumb", "preview", "cover":
            respondThumbnail(request: request, route: route, library: library, host: host, respond: respond)

        case "original":
            respondOriginal(request: request, library: library,
                            allowedAlbumIDs: settings.photoNode.allowedAlbumIDs,
                            respond: respond)

        case "info":
            guard let id = request.query["id"], let info = library.assetInfo(identifier: id) else {
                respond(.error(404, "照片不存在"))
                return
            }
            if let allowed = library.allowedAssetIdentifiers(allowedAlbumIDs: settings.photoNode.allowedAlbumIDs),
               !allowed.contains(id) {
                respond(.error(403, "该照片所在相册未开启共享"))
                return
            }
            respond(.json(["ok": true, "asset": assetJSON(info)]))

        case "status":
            respond(.json([
                "ok": true,
                "authorized": library.isAuthorized,
                "authorizationStatus": authorizationStatusText(library.authorizationStatus),
                "allowedAlbumIDs": context.role == .guest ? [] : settings.photoNode.allowedAlbumIDs
            ]))

        default:
            respond(.error(404, "未实现的 PhotoNode 接口：\(route)"))
        }
    }

    // MARK: - 列表

    private func respondAlbums(library: PitHubPhotoLibrary, settings: PitHubSettings,
                               respond: @escaping (HTTPResponse) -> Void) {
        let albums = library.albums(allowedIDs: settings.photoNode.allowedAlbumIDs)
        let payload: [String: Any] = [
            "ok": true,
            "albums": albums.map { album -> [String: Any] in
                [
                    "id": album.id,
                    "title": album.title,
                    "count": album.count,
                    "kind": album.kind,
                    "coverAssetID": album.coverAssetID ?? ""
                ]
            }
        ]
        var response = HTTPResponse.json(payload)
        response.logAction = "photo-albums"
        respond(response)
    }

    private func respondAssets(request: HTTPRequest, library: PitHubPhotoLibrary,
                               settings: PitHubSettings, respond: @escaping (HTTPResponse) -> Void) {
        let albumID = normalizedAlbumID(request.query["album"])
        let year = request.query["year"].flatMap { Int($0) }
        let month = request.query["month"].flatMap { Int($0) }
        let offset = Int(request.query["offset"] ?? "0") ?? 0
        let limit = Int(request.query["limit"] ?? "120") ?? 120

        let result = library.assets(
            albumID: albumID,
            allowedAlbumIDs: settings.photoNode.allowedAlbumIDs,
            includeVideos: settings.photoNode.includeVideos,
            includeHidden: settings.photoNode.includeHiddenAssets,
            year: year,
            month: month,
            offset: offset,
            limit: limit
        )
        let payload: [String: Any] = [
            "ok": true,
            "album": albumID ?? "all",
            "offset": offset,
            "limit": limit,
            "total": result.total,
            "items": result.items.map { assetJSON($0) }
        ]
        var response = HTTPResponse.json(payload)
        response.logAction = "photo-assets"
        respond(response)
    }

    // MARK: - 缩略图

    private func respondThumbnail(request: HTTPRequest, route: String,
                                  library: PitHubPhotoLibrary, host: PitHubPluginHost,
                                  respond: @escaping (HTTPResponse) -> Void) {
        let rawSize = request.query["size"] ?? (route == "cover" ? "medium" : "small")
        let pixel = pixelSize(from: rawSize)

        let assetID: String?
        if route == "cover" {
            let albumID = normalizedAlbumID(request.query["album"])
            let albums = library.albums(allowedIDs: host.settingsSnapshot.photoNode.allowedAlbumIDs)
            let album = albums.first { albumID == nil || $0.id == albumID }
            assetID = album?.coverAssetID
        } else {
            assetID = request.query["id"]
        }

        guard let assetID,
              let asset = library.asset(identifier: assetID),
              let info = library.assetInfo(identifier: assetID) else {
            respond(.error(404, "照片不存在"))
            return
        }
        if let allowed = library.allowedAssetIdentifiers(allowedAlbumIDs: host.settingsSnapshot.photoNode.allowedAlbumIDs),
           !allowed.contains(assetID) {
            respond(.error(403, "该照片所在相册未开启共享"))
            return
        }

        let quality = CGFloat(max(30, min(100, host.settingsSnapshot.photoNode.thumbnailQuality))) / 100.0
        let cacheKey = "photo:\(assetID):\(Int(pixel)):\(Int(info.modifiedAt.timeIntervalSince1970)):\(Int(quality * 100))"
        if let cached = host.thumbnailCache.data(forKey: cacheKey) {
            respond(jpegResponse(cached, action: "photo-thumb"))
            return
        }

        library.thumbnailData(for: asset, maxPixel: pixel, quality: quality) { data in
            guard let data else {
                respond(.error(404, "缩略图生成失败"))
                return
            }
            _ = host.thumbnailCache.store(data: data, forKey: cacheKey)
            respond(self.jpegResponse(data, action: "photo-thumb"))
        }
    }

    private func jpegResponse(_ data: Data, action: String) -> HTTPResponse {
        var response = HTTPResponse(status: 200, body: .data(data), logAction: action)
        response.headers["Content-Type"] = "image/jpeg"
        response.headers["Cache-Control"] = "public, max-age=86400"
        return response
    }

    // MARK: - 原图

    private func respondOriginal(request: HTTPRequest, library: PitHubPhotoLibrary,
                                 allowedAlbumIDs: [String],
                                 respond: @escaping (HTTPResponse) -> Void) {
        guard let id = request.query["id"], let asset = library.asset(identifier: id) else {
            respond(.error(404, "照片不存在"))
            return
        }
        if let allowed = library.allowedAssetIdentifiers(allowedAlbumIDs: allowedAlbumIDs),
           !allowed.contains(id) {
            respond(.error(403, "该照片所在相册未开启共享"))
            return
        }
        let resource: PitHubPhotoResource = request.query["live"] == "video" ? .pairedVideo : .original
        let inline = request.query["inline"] == "1" || request.query["inline"] == "true"
        let filename = library.originalFilename(for: asset, resource: resource)
        let destination = exportDirectory.appendingPathComponent(
            UUID().uuidString + "-" + filename.sanitizedFileName
        )
        try? PitHubPaths.ensureDirectory(exportDirectory)

        library.export(asset: asset, resource: resource, to: destination) { result in
            switch result {
            case .failure(let error):
                respond(.error(404, "导出失败：\(error.localizedDescription)"))
            case .success(let name):
                let contentType = resource == .pairedVideo ? "video/quicktime" : PitHubMIME.type(for: name)
                var response = HTTPResponse.file(
                    url: destination,
                    contentType: contentType,
                    downloadName: name,
                    inline: inline,
                    supportsRange: true,
                    cleanup: true,
                    action: "photo-original"
                )
                response.headers["Cache-Control"] = "no-store"
                respond(response)
            }
        }
    }

    // MARK: - 工具

    private func normalizedAlbumID(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    private func pixelSize(from raw: String) -> CGFloat {
        switch raw.lowercased() {
        case "small": return 240
        case "medium": return 720
        case "large": return 1600
        default:
            let value = CGFloat(Int(raw) ?? 240)
            return max(64, min(2048, value))
        }
    }

    private func assetJSON(_ asset: PitHubPhotoAsset) -> [String: Any] {
        [
            "id": asset.id,
            "filename": asset.filename,
            "mediaType": asset.mediaType,
            "isLivePhoto": asset.isLivePhoto,
            "isFavorite": asset.isFavorite,
            "width": asset.pixelWidth,
            "height": asset.pixelHeight,
            "duration": asset.duration,
            "createdAt": PitHubFormat.iso(asset.createdAt),
            "modifiedAt": PitHubFormat.iso(asset.modifiedAt),
            "mimeType": asset.mimeType,
            "thumbURL": "/api/photo/thumb?id=\(asset.id.urlQueryEncoded)&size=small",
            "previewURL": "/api/photo/thumb?id=\(asset.id.urlQueryEncoded)&size=large",
            "originalURL": "/api/photo/original?id=\(asset.id.urlQueryEncoded)"
        ]
    }

    private func authorizationStatusText(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .limited: return "limited"
        case .denied: return "denied"
        case .restricted: return "restricted"
        default: return "notDetermined"
        }
    }
}
