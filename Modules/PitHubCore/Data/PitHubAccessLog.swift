//
//  PitHubAccessLog.swift
//  PitHubCore
//
//  访问日志：内存环形缓冲 + JSONL 追加落盘。支持分页、筛选、导出。
//

import Foundation

public struct PitHubAccessLogEntry: Codable, Identifiable, Equatable {
    public var id: String
    public var date: Date
    public var ip: String
    public var method: String
    public var path: String
    public var action: String
    public var role: String
    public var status: Int
    public var bytesIn: Int64
    public var bytesOut: Int64
    public var tunnel: Bool

    public init(id: String = UUID().uuidString,
                date: Date = Date(),
                ip: String,
                method: String,
                path: String,
                action: String,
                role: String,
                status: Int,
                bytesIn: Int64,
                bytesOut: Int64,
                tunnel: Bool) {
        self.id = id
        self.date = date
        self.ip = ip
        self.method = method
        self.path = path
        self.action = action
        self.role = role
        self.status = status
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.tunnel = tunnel
    }

    public func jsonObject() -> [String: Any] {
        [
            "id": id,
            "date": PitHubFormat.iso(date),
            "ip": ip,
            "method": method,
            "path": path,
            "action": action,
            "role": role,
            "status": status,
            "bytesIn": bytesIn,
            "bytesOut": bytesOut,
            "tunnel": tunnel
        ]
    }
}

public final class PitHubAccessLogStore {

    private let lock = NSLock()
    private var entries: [PitHubAccessLogEntry] = []
    private let capacity: Int
    private let fileURL: URL
    private let ioQueue = DispatchQueue(label: "com.pithub.log.io", qos: .utility)

    public init(fileURL: URL? = nil, capacity: Int = 5000) {
        self.fileURL = fileURL ?? PitHubPaths.logs.appendingPathComponent("access.jsonl")
        self.capacity = max(100, capacity)
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded: [PitHubAccessLogEntry] = []
        for line in data.split(separator: 0x0A) {
            if line.isEmpty { continue }
            if let entry = try? decoder.decode(PitHubAccessLogEntry.self, from: Data(line)) {
                loaded.append(entry)
            }
        }
        if loaded.count > capacity {
            loaded.removeFirst(loaded.count - capacity)
        }
        entries = loaded
    }

    public func append(_ entry: PitHubAccessLogEntry) {
        lock.lock()
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        lock.unlock()

        let url = fileURL
        ioQueue.async {
            do {
                try PitHubPaths.ensureDirectory(url.deletingLastPathComponent())
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(entry)
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.write(contentsOf: Data([0x0A]))
                try handle.close()
            } catch {
                PitHubLog.error("访问日志写入失败：\(error.localizedDescription)")
            }
        }
    }

    /// 最新的在前
    public func page(offset: Int, limit: Int, query: String = "", method: String = "", tunnelOnly: Bool? = nil) -> (items: [PitHubAccessLogEntry], total: Int) {
        lock.lock()
        var filtered = entries.reversed().filter { entry in
            if !query.isEmpty {
                let haystack = "\(entry.ip) \(entry.path) \(entry.action) \(entry.role)".lowercased()
                if !haystack.contains(query.lowercased()) { return false }
            }
            if !method.isEmpty, entry.method != method.uppercased() { return false }
            if let tunnelOnly, entry.tunnel != tunnelOnly { return false }
            return true
        }
        let total = filtered.count
        let start = max(0, offset)
        let safeLimit = min(max(1, limit), 500)
        if start >= filtered.count {
            filtered = []
        } else {
            filtered = Array(filtered[start..<min(filtered.count, start + safeLimit)])
        }
        lock.unlock()
        return (Array(filtered), total)
    }

    public func recent(limit: Int = 20) -> [PitHubAccessLogEntry] {
        lock.lock(); defer { lock.unlock() }
        return Array(entries.suffix(max(1, limit)).reversed())
    }

    public func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
        ioQueue.async { [fileURL] in
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    public func exportJSON() -> Data {
        let snapshot: [PitHubAccessLogEntry]
        lock.lock()
        snapshot = entries.reversed()
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(snapshot)) ?? Data("[]".utf8)
    }

    public func exportText() -> Data {
        let snapshot: [PitHubAccessLogEntry]
        lock.lock()
        snapshot = entries.reversed()
        lock.unlock()
        var lines = ["# PitHub 访问日志导出 \(PitHubFormat.iso())", "# 时间\tIP\t方法\t路径\t操作\t角色\t状态\t隧道\t上行\t下行"]
        for entry in snapshot {
            lines.append([
                PitHubFormat.iso(entry.date),
                entry.ip,
                entry.method,
                entry.path,
                entry.action,
                entry.role,
                String(entry.status),
                entry.tunnel ? "tunnel" : "lan",
                String(entry.bytesIn),
                String(entry.bytesOut)
            ].joined(separator: "\t"))
        }
        return Data(lines.joined(separator: "\n").utf8)
    }
}
