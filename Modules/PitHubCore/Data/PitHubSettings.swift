//
//  PitHubSettings.swift
//  PitHubCore
//
//  全局配置模型。网页设置面板与 App 本机设置共用同一份 JSON（数据同源）。
//

import Foundation

public enum PitHubTunnelProvider: String, Codable, CaseIterable, Hashable {
    case none
    case cloudflare
    case relay
    case frp

    public var displayName: String {
        switch self {
        case .none: return "仅局域网"
        case .cloudflare: return "Cloudflare Tunnel"
        case .relay: return "PitHub Relay 自建隧道"
        case .frp: return "frp（外部客户端）"
        }
    }
}

public enum PitHubBackgroundPolicy: String, Codable, CaseIterable, Hashable {
    case pauseOnLock
    case keepAlive

    public var displayName: String {
        switch self {
        case .pauseOnLock: return "锁屏暂停服务"
        case .keepAlive: return "锁屏尽量保活"
        }
    }
}

public struct PitHubFilePitSettings: Codable, Equatable {
    public var maxUploadMB: Int = 4096
    public var blockedExtensions: [String] = [
        "exe", "bat", "cmd", "com", "msi", "scr", "ps1", "vbs", "js", "jar",
        "dylib", "so", "app", "dmg", "pkg", "sh", "apk", "deb"
    ]
    public var shareExpiryMinutes: Int = 60
    public var allowZipDownload: Bool = true
    public var allowPhotoMount: Bool = true
    public var chunkMB: Int = 8

    public init() {}
}

public struct PitHubPhotoNodeSettings: Codable, Equatable {
    /// 为空表示共享全部相册；否则只共享列出的相册 localIdentifier
    public var allowedAlbumIDs: [String] = []
    public var includeHiddenAssets: Bool = false
    public var includeVideos: Bool = true
    public var thumbnailQuality: Int = 72

    public init() {}
}

public struct PitHubClipHubSettings: Codable, Equatable {
    public var maxRecords: Int = 200
    public var maxItemMB: Int = 16
    public var retentionDays: Int = 30

    public init() {}
}

public struct PitHubDashLinkSettings: Codable, Equatable {
    public var cooldownSeconds: Int = 10
    public var maxRuns: Int = 300

    public init() {}
}

public struct PitHubSettings: Codable, Equatable {

    // 服务
    public var port: Int = 8080
    public var bonjourName: String = "PitHub"
    public var guestEnabled: Bool = true
    public var sessionTimeoutMinutes: Int = 720

    // 鉴权（只保存加盐哈希，不保存明文）
    public var accessPasswordHash: String = ""
    public var accessPasswordSalt: String = ""
    public var adminPasswordHash: String = ""
    public var adminPasswordSalt: String = ""
    public var isDefaultPassword: Bool = true

    // 隧道
    public var tunnelEnabled: Bool = false
    public var tunnelProvider: PitHubTunnelProvider = .cloudflare
    /// Cloudflare 模式下由外部连接器提供的公网地址（例如 https://xxx.trycloudflare.com）
    public var tunnelPublicURL: String = ""
    public var relayURL: String = ""
    public var relayToken: String = ""
    public var wanRateLimitKBps: Int = 0

    // 后台策略
    public var backgroundPolicy: PitHubBackgroundPolicy = .pauseOnLock
    public var preventAutoLock: Bool = true

    // 插件
    public var pluginEnabled: [String: Bool] = [
        "file": true,
        "photo": true,
        "clip": false,
        "dash": false
    ]
    public var filePit: PitHubFilePitSettings = PitHubFilePitSettings()
    public var photoNode: PitHubPhotoNodeSettings = PitHubPhotoNodeSettings()
    public var clipHub: PitHubClipHubSettings = PitHubClipHubSettings()
    public var dashLink: PitHubDashLinkSettings = PitHubDashLinkSettings()

    // 系统
    public var cacheLimitMB: Int = 512
    public var logRetention: Int = 5000
    public var notificationsEnabled: Bool = true
    public var biometricForSensitive: Bool = false

    public init() {}

    /// 返回可以安全下发给网页的配置（不包含密码哈希）
    public func publicJSON() -> [String: Any] {
        var dict: [String: Any] = [:]
        dict["port"] = port
        dict["bonjourName"] = bonjourName
        dict["guestEnabled"] = guestEnabled
        dict["sessionTimeoutMinutes"] = sessionTimeoutMinutes
        dict["isDefaultPassword"] = isDefaultPassword
        dict["tunnelEnabled"] = tunnelEnabled
        dict["tunnelProvider"] = tunnelProvider.rawValue
        dict["tunnelPublicURL"] = tunnelPublicURL
        dict["relayURL"] = relayURL
        dict["relayTokenConfigured"] = !relayToken.isEmpty
        dict["wanRateLimitKBps"] = wanRateLimitKBps
        dict["backgroundPolicy"] = backgroundPolicy.rawValue
        dict["preventAutoLock"] = preventAutoLock
        dict["pluginEnabled"] = pluginEnabled
        dict["cacheLimitMB"] = cacheLimitMB
        dict["logRetention"] = logRetention
        dict["notificationsEnabled"] = notificationsEnabled
        dict["biometricForSensitive"] = biometricForSensitive

        dict["filePit"] = [
            "maxUploadMB": filePit.maxUploadMB,
            "blockedExtensions": filePit.blockedExtensions,
            "shareExpiryMinutes": filePit.shareExpiryMinutes,
            "allowZipDownload": filePit.allowZipDownload,
            "allowPhotoMount": filePit.allowPhotoMount,
            "chunkMB": filePit.chunkMB
        ]
        dict["photoNode"] = [
            "allowedAlbumIDs": photoNode.allowedAlbumIDs,
            "includeHiddenAssets": photoNode.includeHiddenAssets,
            "includeVideos": photoNode.includeVideos,
            "thumbnailQuality": photoNode.thumbnailQuality
        ]
        dict["clipHub"] = [
            "maxRecords": clipHub.maxRecords,
            "maxItemMB": clipHub.maxItemMB,
            "retentionDays": clipHub.retentionDays
        ]
        dict["dashLink"] = [
            "cooldownSeconds": dashLink.cooldownSeconds,
            "maxRuns": dashLink.maxRuns
        ]
        return dict
    }
}
