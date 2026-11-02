//
//  FilePitModels.swift
//  PitHubFilePit
//

import Foundation
import PitHubCore

public struct FilePitEntry: Codable, Identifiable, Equatable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Double
    public var kind: String
    public var mime: String
    public var isReadOnly: Bool
    public var rootID: String
    public var isLivePhoto: Bool
    public var duration: Double
    public var assetCount: Int

    public init(name: String,
                path: String,
                isDirectory: Bool,
                size: Int64 = 0,
                modified: Double = 0,
                kind: String = "file",
                mime: String = "application/octet-stream",
                isReadOnly: Bool = false,
                rootID: String = "",
                isLivePhoto: Bool = false,
                duration: Double = 0,
                assetCount: Int = 0) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.kind = kind
        self.mime = mime
        self.isReadOnly = isReadOnly
        self.rootID = rootID
        self.isLivePhoto = isLivePhoto
        self.duration = duration
        self.assetCount = assetCount
    }

    public func jsonObject() -> [String: Any] {
        [
            "name": name,
            "path": path,
            "isDirectory": isDirectory,
            "size": size,
            "modified": modified,
            "kind": kind,
            "mime": mime,
            "isReadOnly": isReadOnly,
            "rootID": rootID,
            "isLivePhoto": isLivePhoto,
            "duration": duration,
            "assetCount": assetCount
        ]
    }
}

public struct FilePitRootInfo: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var path: String
    public var readOnly: Bool
    public var adminOnly: Bool
    public var available: Bool
}

struct FilePitShare: Codable, Equatable {
    var token: String
    var virtualPath: String
    var fileName: String
    var createdAt: Date
    var expiresAt: Date
    var passwordSalt: String
    var passwordHash: String
    var creatorRole: String

    var isPasswordProtected: Bool { !passwordHash.isEmpty }

    var isExpired: Bool { expiresAt <= Date() }

    func jsonObject(baseURL: String) -> [String: Any] {
        [
            "token": token,
            "path": virtualPath,
            "fileName": fileName,
            "createdAt": PitHubFormat.iso(createdAt),
            "expiresAt": PitHubFormat.iso(expiresAt),
            "passwordProtected": isPasswordProtected,
            "expired": isExpired,
            "url": "\(baseURL)/s/\(token)"
        ]
    }
}

struct FilePitUploadSession: Codable, Equatable {
    var id: String
    var virtualPath: String
    var fileName: String
    var totalSize: Int64
    var chunkSize: Int64
    var totalChunks: Int
    var received: [Int]
    var createdAt: Date

    var receivedSet: Set<Int> { Set(received) }

    var missingChunks: [Int] {
        guard totalChunks > 0 else { return [] }
        let set = receivedSet
        return (0..<totalChunks).filter { !set.contains($0) }
    }

    var progress: Double {
        guard totalChunks > 0 else { return received.isEmpty ? 1.0 : 0.0 }
        return Double(received.count) / Double(totalChunks)
    }

    func jsonObject() -> [String: Any] {
        [
            "uploadId": id,
            "path": virtualPath,
            "fileName": fileName,
            "totalSize": totalSize,
            "chunkSize": chunkSize,
            "totalChunks": totalChunks,
            "received": received.sorted(),
            "missing": missingChunks,
            "createdAt": PitHubFormat.iso(createdAt),
            "progress": progress
        ]
    }
}

enum FilePitError: LocalizedError {
    case invalidPath
    case forbidden(String)
    case notFound(String)
    case conflict(String)
    case readOnly
    case tooLarge(String)
    case blockedExtension(String)
    case invalidOperation(String)
    case io(String)
    case noPhotoPermission

    var status: Int {
        switch self {
        case .invalidPath: return 400
        case .forbidden: return 403
        case .notFound: return 404
        case .conflict: return 409
        case .readOnly: return 403
        case .tooLarge: return 413
        case .blockedExtension: return 415
        case .invalidOperation: return 400
        case .io: return 500
        case .noPhotoPermission: return 403
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidPath: return "路径无效"
        case .forbidden(let message): return message
        case .notFound(let message): return message
        case .conflict(let message): return message
        case .readOnly: return "该目录为只读"
        case .tooLarge(let message): return message
        case .blockedExtension(let ext): return "出于安全考虑，禁止上传 .\(ext) 文件"
        case .invalidOperation(let message): return message
        case .io(let message): return message
        case .noPhotoPermission: return "尚未获得相册访问权限，请在 PitHub App 中授权"
        }
    }

    func response() -> HTTPResponse {
        var response = HTTPResponse.json(["ok": false, "error": errorDescription ?? "操作失败"], status: status)
        response.logAction = "error"
        return response
    }
}
