//
//  PitHubCache.swift
//  PitHubCore
//
//  统一 LRU 磁盘缓存：缩略图、ZIP、预览图共用。
//  以"最后访问时间"为依据淘汰，避免频繁扫描大目录。
//

import Foundation
import CryptoKit

public final class PitHubLRUCache {

    public let directory: URL
    private var limit: Int64
    private let lock = NSLock()

    public init(directory: URL, maxBytes: Int64) {
        self.directory = directory
        self.limit = max(8 * 1024 * 1024, maxBytes)
        try? PitHubPaths.ensureDirectory(directory)
    }

    public var maxBytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        return limit
    }

    public func setMaxBytes(_ bytes: Int64) {
        lock.lock()
        limit = max(8 * 1024 * 1024, bytes)
        lock.unlock()
        evictIfNeeded()
    }

    private func fileName(for key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined() + ".cac"
    }

    public func url(forKey key: String) -> URL {
        directory.appendingPathComponent(fileName(for: key))
    }

    public func data(forKey key: String) -> Data? {
        let target = url(forKey: key)
        guard let data = try? Data(contentsOf: target) else { return nil }
        touch(target)
        return data
    }

    public func fileURL(forKey key: String) -> URL? {
        let target = url(forKey: key)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        touch(target)
        return target
    }

    public func contains(key: String) -> Bool {
        FileManager.default.fileExists(atPath: url(forKey: key).path)
    }

    @discardableResult
    public func store(data: Data, forKey key: String) -> Bool {
        do {
            try PitHubPaths.ensureDirectory(directory)
            try data.write(to: url(forKey: key), options: .atomic)
            evictIfNeeded()
            return true
        } catch {
            PitHubLog.error("缓存写入失败：\(error.localizedDescription)")
            return false
        }
    }

    public func store(fileAt source: URL, forKey key: String) throws {
        let target = url(forKey: key)
        try PitHubPaths.ensureDirectory(directory)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: source, to: target)
        evictIfNeeded()
    }

    private func touch(_ url: URL) {
        let now = Date()
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
    }

    public func remove(forKey key: String) {
        try? FileManager.default.removeItem(at: url(forKey: key))
    }

    public func clear() {
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for item in items { try? fm.removeItem(at: item) }
        }
    }

    public var totalBytes: Int64 {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(into: Int64(0)) { result, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            result += Int64(size)
        }
    }

    private func evictIfNeeded() {
        lock.lock()
        let currentLimit = limit
        lock.unlock()

        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }

        var records: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0
        for item in items {
            let values = try? item.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            let date = values?.contentModificationDate ?? Date.distantPast
            total += size
            records.append((item, size, date))
        }
        if total <= currentLimit { return }
        records.sort { $0.date < $1.date }
        for record in records {
            if total <= currentLimit { break }
            try? fm.removeItem(at: record.url)
            total -= record.size
        }
    }
}
