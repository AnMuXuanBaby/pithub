//
//  PitHubSettingsStore.swift
//  PitHubCore
//
//  配置文件读写。所有修改都通过 update(_:) 完成：
//  - 用锁保证 HTTP 线程读取安全；
//  - 用 @Published 让 SwiftUI 自动刷新；
//  - 落盘在后台队列做原子写入。
//

import Foundation
import Combine

public final class PitHubSettingsStore: ObservableObject {

    @Published public private(set) var settings: PitHubSettings

    private var storage: PitHubSettings
    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "com.pithub.settings.io", qos: .utility)
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        let url = fileURL ?? PitHubPaths.config.appendingPathComponent("settings.json")
        self.fileURL = url

        var loaded: PitHubSettings
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(PitHubSettings.self, from: data) {
            loaded = decoded
        } else {
            loaded = PitHubSettings()
        }

        // 首次启动或配置损坏：写入默认密码 pithub（网页/WebDAV 可立即使用）
        if loaded.accessPasswordHash.isEmpty || loaded.accessPasswordSalt.isEmpty {
            let salt = PitHubPassword.makeSalt()
            loaded.accessPasswordSalt = salt
            loaded.accessPasswordHash = PitHubPassword.hash("pithub", salt: salt)
            loaded.adminPasswordSalt = salt
            loaded.adminPasswordHash = loaded.accessPasswordHash
            loaded.isDefaultPassword = true
        }

        self.storage = loaded
        self.settings = loaded
        saveNow()
    }

    /// 线程安全的当前配置快照
    public var current: PitHubSettings {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    /// 修改配置并持久化
    public func update(_ mutate: (inout PitHubSettings) -> Void) {
        lock.lock()
        var copy = storage
        mutate(&copy)
        storage = copy
        lock.unlock()

        if Thread.isMainThread {
            settings = copy
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.settings = copy
            }
        }
        persist(copy)
    }

    public func saveNow() {
        persist(current)
    }

    private func persist(_ value: PitHubSettings) {
        let url = fileURL
        ioQueue.async {
            do {
                try PitHubPaths.ensureDirectory(url.deletingLastPathComponent())
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(value)
                try data.write(to: url, options: .atomic)
            } catch {
                PitHubLog.error("配置保存失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 密码便捷操作

    public func setAccessPassword(_ password: String) {
        let salt = PitHubPassword.makeSalt()
        update { settings in
            settings.accessPasswordSalt = salt
            settings.accessPasswordHash = PitHubPassword.hash(password, salt: salt)
            settings.isDefaultPassword = false
        }
    }

    public func setAdminPassword(_ password: String) {
        let salt = PitHubPassword.makeSalt()
        update { settings in
            settings.adminPasswordSalt = salt
            settings.adminPasswordHash = PitHubPassword.hash(password, salt: salt)
            if settings.adminPasswordHash.isEmpty {
                settings.adminPasswordHash = settings.accessPasswordHash
                settings.adminPasswordSalt = settings.accessPasswordSalt
            }
        }
    }

    public func verifyAccessPassword(_ password: String) -> Bool {
        let snapshot = current
        return PitHubPassword.verify(password, salt: snapshot.accessPasswordSalt, hash: snapshot.accessPasswordHash)
    }

    public func verifyAdminPassword(_ password: String) -> Bool {
        let snapshot = current
        if snapshot.adminPasswordHash.isEmpty {
            return PitHubPassword.verify(password, salt: snapshot.accessPasswordSalt, hash: snapshot.accessPasswordHash)
        }
        return PitHubPassword.verify(password, salt: snapshot.adminPasswordSalt, hash: snapshot.adminPasswordHash)
    }
}
