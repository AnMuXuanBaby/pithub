//
//  PitHubPluginManager.swift
//  PitHubCore
//

import Foundation
import Combine

public final class PitHubPluginManager: ObservableObject {

    public let plugins: [PitHubPlugin]

    @Published public private(set) var enabledIDs: Set<String>

    private let lock = NSLock()
    private var storage: Set<String>

    public init(plugins: [PitHubPlugin], enabledStates: [String: Bool]) {
        self.plugins = plugins
        var ids = Set<String>()
        for plugin in plugins {
            let enabled = enabledStates[plugin.id] ?? plugin.defaultEnabled
            if enabled { ids.insert(plugin.id) }
        }
        self.storage = ids
        self.enabledIDs = ids
    }

    public func apply(enabledStates: [String: Bool]) {
        var ids = Set<String>()
        for plugin in plugins {
            let enabled = enabledStates[plugin.id] ?? plugin.defaultEnabled
            if enabled { ids.insert(plugin.id) }
        }
        setEnabledIDs(ids)
    }

    public func setEnabled(_ enabled: Bool, id: String) {
        lock.lock()
        var ids = storage
        if enabled { ids.insert(id) } else { ids.remove(id) }
        storage = ids
        lock.unlock()
        setEnabledIDs(ids)
    }

    private func setEnabledIDs(_ ids: Set<String>) {
        lock.lock()
        storage = ids
        lock.unlock()
        if Thread.isMainThread {
            enabledIDs = ids
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.enabledIDs = ids
            }
        }
    }

    public func isEnabled(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return storage.contains(id)
    }

    public func plugin(id: String) -> PitHubPlugin? {
        plugins.first { $0.id == id }
    }

    /// 按最长前缀匹配插件路由。即使插件被禁用也会返回，方便上层统一返回 404。
    public func match(path: String) -> (plugin: PitHubPlugin, subPath: String)? {
        var best: (plugin: PitHubPlugin, subPath: String, length: Int)?
        for plugin in plugins {
            for prefix in ([plugin.apiPrefix] + plugin.extraPrefixes) {
                guard !prefix.isEmpty else { continue }
                // 必须按路径边界匹配，避免 /s 误吞 /settings、/api/file 误吞 /api/filex
                guard path == prefix || path.hasPrefix(prefix + "/") else { continue }
                let subPath = String(path.dropFirst(prefix.count))
                if let current = best {
                    if prefix.count > current.length {
                        best = (plugin, subPath, prefix.count)
                    }
                } else {
                    best = (plugin, subPath, prefix.count)
                }
            }
        }
        guard let best else { return nil }
        return (best.plugin, best.subPath)
    }

    public func descriptors(settings: PitHubSettings) -> [PitHubPluginDescriptor] {
        plugins.map { plugin in
            PitHubPluginDescriptor(
                id: plugin.id,
                name: plugin.displayName,
                summary: plugin.summary,
                systemImage: plugin.systemImage,
                prefix: plugin.apiPrefix,
                enabled: settings.pluginEnabled[plugin.id] ?? plugin.defaultEnabled,
                defaultEnabled: plugin.defaultEnabled
            )
        }
    }
}
