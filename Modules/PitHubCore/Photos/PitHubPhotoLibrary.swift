//
//  PitHubPhotoLibrary.swift
//  PitHubCore
//
//  PhotoKit 读取封装。PhotoNode 与 FilePit（相册只读挂载）共用，
//  所有缩略图都通过系统 PHImageManager 生成，不读取第三方数据。
//
//  沙盒限制：不能直接拿到相册文件的 URL，只能用 PHAssetResourceManager
//  导出到临时目录后再流式下发（见 exportOriginal）。
//

import Foundation
import Photos
import UIKit

public struct PitHubPhotoAlbum: Identifiable, Equatable {
    public var id: String
    public var title: String
    public var count: Int
    public var kind: String          // user / smart
    public var coverAssetID: String?
}

public struct PitHubPhotoAsset: Identifiable, Equatable {
    public var id: String
    public var filename: String
    public var mediaType: String     // image / video
    public var isLivePhoto: Bool
    public var isFavorite: Bool
    public var width: Int
    public var height: Int
    public var duration: Double
    public var createdAt: Date
    public var modifiedAt: Date
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var mimeType: String
}

public struct PitHubPhotoBucket: Equatable {
    public var year: Int
    public var month: Int
    public var count: Int
}

public enum PitHubPhotoResource {
    case original
    case pairedVideo
}

public final class PitHubPhotoLibrary {

    public static let shared = PitHubPhotoLibrary()

    private let imageManager = PHCachingImageManager()
    private let countCacheLock = NSLock()
    private var countCache: [String: (count: Int, date: Date)] = [:]
    private var allowedAssetCache: [String: (date: Date, ids: Set<String>)] = [:]

    private init() {}

    // MARK: - 权限

    public var authorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    public var isAuthorized: Bool {
        let status = authorizationStatus
        return status == .authorized || status == .limited
    }

    public func requestAccess(completion: @escaping (PHAuthorizationStatus) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async { completion(status) }
        }
    }

    // MARK: - 相册

    public func albums(allowedIDs: [String]) -> [PitHubPhotoAlbum] {
        guard isAuthorized else { return [] }
        var result: [PitHubPhotoAlbum] = []

        if allowedIDs.isEmpty {
            let all = PHAsset.fetchAssets(with: nil)
            result.append(PitHubPhotoAlbum(id: "all", title: "全部照片", count: all.count, kind: "virtual", coverAssetID: nil))
        }

        let userAlbums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        userAlbums.enumerateObjects { collection, _, _ in
            if !allowedIDs.isEmpty && !allowedIDs.contains(collection.localIdentifier) { return }
            // 注意：不能信任 estimatedAssetCount（可能不准），这里按需统计并缓存
            let count = self.cachedCount(for: collection)
            result.append(PitHubPhotoAlbum(
                id: collection.localIdentifier,
                title: collection.localizedTitle ?? "未命名相册",
                count: count,
                kind: "user",
                coverAssetID: self.coverAssetID(for: collection)
            ))
        }

        let smartAlbums = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil)
        smartAlbums.enumerateObjects { collection, _, _ in
            if !allowedIDs.isEmpty && !allowedIDs.contains(collection.localIdentifier) { return }
            let type = collection.assetCollectionSubtype
            // 只保留对用户有意义、且系统稳定提供的智能相册
            let allowedTypes: [PHAssetCollectionSubtype] = [
                .smartAlbumUserLibrary, .smartAlbumFavorites, .smartAlbumVideos,
                .smartAlbumLivePhotos, .smartAlbumRecentlyAdded, .smartAlbumScreenshots
            ]
            guard allowedTypes.contains(type) else { return }
            let count = self.cachedCount(for: collection)
            guard count > 0 else { return }
            result.append(PitHubPhotoAlbum(
                id: collection.localIdentifier,
                title: collection.localizedTitle ?? "智能相册",
                count: count,
                kind: "smart",
                coverAssetID: self.coverAssetID(for: collection)
            ))
        }

        return result
    }

    private func cachedCount(for collection: PHAssetCollection) -> Int {
        let key = collection.localIdentifier
        countCacheLock.lock()
        if let cached = countCache[key], Date().timeIntervalSince(cached.date) < 120 {
            countCacheLock.unlock()
            return cached.count
        }
        countCacheLock.unlock()

        let count = PHAsset.fetchAssets(in: collection, options: nil).count
        countCacheLock.lock()
        countCache[key] = (count, Date())
        countCacheLock.unlock()
        return count
    }

    private func coverAssetID(for collection: PHAssetCollection) -> String? {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        return PHAsset.fetchAssets(in: collection, options: options).firstObject?.localIdentifier
    }

    // MARK: - 资源列表

    public func assets(albumID: String?,
                       allowedAlbumIDs: [String],
                       includeVideos: Bool,
                       includeHidden: Bool,
                       year: Int?,
                       month: Int?,
                       offset: Int,
                       limit: Int) -> (items: [PitHubPhotoAsset], total: Int) {
        guard isAuthorized else { return ([], 0) }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        var predicates: [NSPredicate] = []
        if !includeHidden {
            predicates.append(NSPredicate(format: "isHidden == false"))
        }
        if !includeVideos {
            predicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue))
        }
        if let year {
            var components = DateComponents()
            components.year = year
            components.month = month ?? 1
            components.day = 1
            let calendar = Calendar.current
            guard let start = calendar.date(from: components),
                  let end = calendar.date(byAdding: month == nil ? .year : .month, value: 1, to: start) else {
                return ([], 0)
            }
            predicates.append(NSPredicate(format: "creationDate >= %@ AND creationDate < %@", start as NSDate, end as NSDate))
        }
        if !predicates.isEmpty {
            options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        }

        let result: PHFetchResult<PHAsset>
        if let albumID, albumID != "all" {
            if !allowedAlbumIDs.isEmpty && !allowedAlbumIDs.contains(albumID) { return ([], 0) }
            guard let collection = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [albumID], options: nil
            ).firstObject else {
                return ([], 0)
            }
            result = PHAsset.fetchAssets(in: collection, options: options)
        } else {
            // 若设置了允许共享的相册，则必须选择具体相册，避免“全部照片”绕过相册白名单
            guard allowedAlbumIDs.isEmpty else { return ([], 0) }
            result = PHAsset.fetchAssets(with: options)
        }

        let total = result.count
        guard total > 0 else { return ([], 0) }
        let start = max(0, offset)
        guard start < total else { return ([], total) }
        let end = min(total, start + max(1, min(limit, 500)))

        var items: [PitHubPhotoAsset] = []
        items.reserveCapacity(end - start)
        for index in start..<end {
            items.append(makeInfo(for: result.object(at: index)))
        }
        return (items, total)
    }

    public func asset(identifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
    }

    /// 相册白名单下的资源 ID 集合。返回 nil 表示未限制（共享全部）。
    /// 用于阻止“知道 asset id 就能绕过相册白名单”的访问。
    public func allowedAssetIdentifiers(allowedAlbumIDs: [String]) -> Set<String>? {
        guard !allowedAlbumIDs.isEmpty else { return nil }
        let key = allowedAlbumIDs.sorted().joined(separator: ",")

        countCacheLock.lock()
        if let cached = allowedAssetCache[key], Date().timeIntervalSince(cached.date) < 60 {
            let ids = cached.ids
            countCacheLock.unlock()
            return ids
        }
        countCacheLock.unlock()

        var identifiers = Set<String>()
        for albumID in allowedAlbumIDs {
            guard let collection = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [albumID], options: nil
            ).firstObject else { continue }
            let result = PHAsset.fetchAssets(in: collection, options: nil)
            result.enumerateObjects { asset, _, _ in
                identifiers.insert(asset.localIdentifier)
            }
        }

        countCacheLock.lock()
        allowedAssetCache[key] = (Date(), identifiers)
        countCacheLock.unlock()
        return identifiers
    }

    public func assetInfo(identifier: String) -> PitHubPhotoAsset? {
        guard let asset = asset(identifier: identifier) else { return nil }
        return makeInfo(for: asset)
    }

    private func makeInfo(for asset: PHAsset) -> PitHubPhotoAsset {
        let resources = PHAssetResource.assetResources(for: asset)
        let primary = resources.first(where: { $0.type == .fullSizePhoto || $0.type == .photo })
            ?? resources.first(where: { $0.type == .fullSizeVideo || $0.type == .video })
            ?? resources.first
        let filename = primary?.originalFilename ?? "\(asset.localIdentifier).jpg"
        let mediaType = asset.mediaType == .video ? "video" : "image"
        let mime = PitHubMIME.type(for: filename)

        return PitHubPhotoAsset(
            id: asset.localIdentifier,
            filename: filename,
            mediaType: mediaType,
            isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
            isFavorite: asset.isFavorite,
            width: asset.pixelWidth,
            height: asset.pixelHeight,
            duration: asset.duration,
            createdAt: asset.creationDate ?? Date(),
            modifiedAt: asset.modificationDate ?? asset.creationDate ?? Date(),
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            mimeType: mime
        )
    }

    // MARK: - 缩略图

    public func thumbnailData(for asset: PHAsset,
                              maxPixel: CGFloat,
                              quality: CGFloat,
                              completion: @escaping (Data?) -> Void) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.version = .current

        let lock = NSLock()
        var finished = false
        let size = CGSize(width: max(64, maxPixel), height: max(64, maxPixel))

        imageManager.requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { image, info in
            lock.lock()
            if finished { lock.unlock(); return }
            if let degraded = info?[PHImageResultIsDegradedKey] as? Bool, degraded {
                lock.unlock()
                return
            }
            finished = true
            lock.unlock()
            let data = image?.jpegData(compressionQuality: max(0.1, min(1.0, quality)))
            completion(data)
        }
    }

    /// 生成较大预览图（用于网页图片查看器）
    public func previewData(for asset: PHAsset,
                            maxPixel: CGFloat,
                            quality: CGFloat,
                            completion: @escaping (Data?) -> Void) {
        thumbnailData(for: asset, maxPixel: maxPixel, quality: quality, completion: completion)
    }

    /// 按 localIdentifier 直接取缩略图（App 本机 UI 使用，避免暴露 PHAsset）
    public func thumbnailData(identifier: String,
                              maxPixel: CGFloat,
                              quality: CGFloat,
                              completion: @escaping (Data?) -> Void) {
        guard let asset = asset(identifier: identifier) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        thumbnailData(for: asset, maxPixel: maxPixel, quality: quality, completion: completion)
    }

    public func previewData(identifier: String,
                            maxPixel: CGFloat,
                            quality: CGFloat,
                            completion: @escaping (Data?) -> Void) {
        thumbnailData(identifier: identifier, maxPixel: maxPixel, quality: quality, completion: completion)
    }

    // MARK: - 原图导出

    public func export(asset: PHAsset,
                       resource: PitHubPhotoResource,
                       to destination: URL,
                       completion: @escaping (Result<String, Error>) -> Void) {
        let resources = PHAssetResource.assetResources(for: asset)
        let selected: PHAssetResource?

        switch resource {
        case .original:
            if asset.mediaType == .video {
                selected = resources.first(where: { $0.type == .fullSizeVideo })
                    ?? resources.first(where: { $0.type == .video })
            } else {
                selected = resources.first(where: { $0.type == .fullSizePhoto })
                    ?? resources.first(where: { $0.type == .photo })
                    ?? resources.first(where: { $0.type == .alternatePhoto })
            }
        case .pairedVideo:
            selected = resources.first(where: { $0.type == .fullSizePairedVideo })
                ?? resources.first(where: { $0.type == .pairedVideo })
        }

        guard let assetResource = selected else {
            completion(.failure(NSError(domain: "PitHub", code: 404, userInfo: [NSLocalizedDescriptionKey: "未找到可导出的相册资源"])))
            return
        }

        try? FileManager.default.removeItem(at: destination)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        PHAssetResourceManager.default().writeData(for: assetResource, toFile: destination, options: options) { error in
            DispatchQueue.global(qos: .utility).async {
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(assetResource.originalFilename))
                }
            }
        }
    }

    public func export(identifier: String,
                       resource: PitHubPhotoResource,
                       to destination: URL,
                       completion: @escaping (Result<String, Error>) -> Void) {
        guard let asset = asset(identifier: identifier) else {
            completion(.failure(NSError(domain: "PitHub", code: 404, userInfo: [NSLocalizedDescriptionKey: "照片不存在"])))
            return
        }
        export(asset: asset, resource: resource, to: destination, completion: completion)
    }

    public func originalFilename(for asset: PHAsset, resource: PitHubPhotoResource = .original) -> String {
        let resources = PHAssetResource.assetResources(for: asset)
        if resource == .pairedVideo {
            if let paired = resources.first(where: { $0.type == .fullSizePairedVideo || $0.type == .pairedVideo }) {
                return paired.originalFilename
            }
            return "\(asset.localIdentifier)-live.mov"
        }
        let primary = resources.first(where: { $0.type == .fullSizePhoto || $0.type == .photo || $0.type == .fullSizeVideo || $0.type == .video })
        return primary?.originalFilename ?? "\(asset.localIdentifier).jpg"
    }

    // MARK: - 时间轴

    public func timeline(albumID: String?, allowedAlbumIDs: [String]) -> [PitHubPhotoBucket] {
        guard isAuthorized else { return [] }
        if !allowedAlbumIDs.isEmpty {
            if let albumID {
                if !allowedAlbumIDs.contains(albumID) { return [] }
            } else {
                return []
            }
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let result: PHFetchResult<PHAsset>
        if let albumID, albumID != "all" {
            guard let collection = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [albumID], options: nil
            ).firstObject else { return [] }
            result = PHAsset.fetchAssets(in: collection, options: options)
        } else {
            result = PHAsset.fetchAssets(with: options)
        }

        var buckets: [String: PitHubPhotoBucket] = [:]
        let calendar = Calendar.current
        result.enumerateObjects { asset, _, _ in
            guard let date = asset.creationDate else { return }
            let comps = calendar.dateComponents([.year, .month], from: date)
            guard let year = comps.year, let month = comps.month else { return }
            let key = "\(year)-\(month)"
            if var existing = buckets[key] {
                existing.count += 1
                buckets[key] = existing
            } else {
                buckets[key] = PitHubPhotoBucket(year: year, month: month, count: 1)
            }
        }
        return buckets.values.sorted { $0.year == $1.year ? $0.month > $1.month : $0.year > $1.year }
    }
}
