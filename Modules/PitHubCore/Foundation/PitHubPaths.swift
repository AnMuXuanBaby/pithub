//
//  PitHubPaths.swift
//  PitHubCore
//
//  统一管理 App 沙盒内的目录。所有插件、缓存、日志都通过这里取路径，
//  保证 WebDAV / 网页 / 本机 UI 看到的是同一份数据。
//

import Foundation

public enum PitHubPaths {

    /// App 私有数据根目录：Library/Application Support/PitHub
    public static let root: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("PitHub", isDirectory: true)
    }()

    /// 用户可见的 Documents/PitHub（开启 UIFileSharingEnabled 后可在“文件”App 中看到）
    public static let documentsRoot: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Documents", isDirectory: true)
        return base.appendingPathComponent("PitHub", isDirectory: true)
    }()

    // MARK: - 全局

    public static var config: URL { root.appendingPathComponent("config", isDirectory: true) }
    public static var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
    public static var cache: URL { root.appendingPathComponent("cache", isDirectory: true) }
    public static var thumbnails: URL { cache.appendingPathComponent("thumbnails", isDirectory: true) }
    public static var zipCache: URL { cache.appendingPathComponent("zip", isDirectory: true) }
    public static var shares: URL { root.appendingPathComponent("shares", isDirectory: true) }
    public static var privateRoot: URL { root.appendingPathComponent("Private", isDirectory: true) }
    public static var pluginData: URL { root.appendingPathComponent("PluginData", isDirectory: true) }
    public static var tempUploads: URL { root.appendingPathComponent("tmp/uploads", isDirectory: true) }
    public static var clipStore: URL { root.appendingPathComponent("ClipHub", isDirectory: true) }

    // MARK: - FilePit 可见目录（放在 Documents 下，方便用“文件”App 直接拷入文件）

    public static var sharedRoot: URL { documentsRoot.appendingPathComponent("Shared", isDirectory: true) }
    public static var uploadsRoot: URL { documentsRoot.appendingPathComponent("Uploads", isDirectory: true) }

    /// 启动时创建所有必要目录。重复调用是安全的。
    public static func bootstrap() throws {
        let fm = FileManager.default
        let dirs: [URL] = [
            root, documentsRoot, config, logs, cache, thumbnails, zipCache,
            shares, privateRoot, pluginData, tempUploads, clipStore,
            sharedRoot, uploadsRoot
        ]
        for dir in dirs {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    public static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// 相对 App 私有根目录显示路径（用于日志，避免暴露完整沙盒路径）
    public static func displayPath(_ url: URL) -> String {
        let path = url.path
        if path.hasPrefix(root.path) {
            return String(path.dropFirst(root.path.count))
        }
        if path.hasPrefix(documentsRoot.path) {
            return String(path.dropFirst(documentsRoot.path.count))
        }
        return url.lastPathComponent
    }
}
