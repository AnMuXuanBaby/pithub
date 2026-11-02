//
//  PitHubTrafficStats.swift
//  PitHubCore
//

import Foundation

public struct PitHubTrafficSnapshot: Codable, Equatable {
    public var lanBytesIn: Int64 = 0
    public var lanBytesOut: Int64 = 0
    public var tunnelBytesIn: Int64 = 0
    public var tunnelBytesOut: Int64 = 0

    public var totalBytesIn: Int64 { lanBytesIn + tunnelBytesIn }
    public var totalBytesOut: Int64 { lanBytesOut + tunnelBytesOut }
    public var totalBytes: Int64 { totalBytesIn + totalBytesOut }

    public init() {}
}

public final class PitHubTrafficStats {

    private let lock = NSLock()
    private var snapshot = PitHubTrafficSnapshot()
    private let persistURL: URL?

    public init(persistURL: URL? = PitHubPaths.config.appendingPathComponent("traffic.json")) {
        self.persistURL = persistURL
        if let url = persistURL,
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(PitHubTrafficSnapshot.self, from: data) {
            snapshot = decoded
        }
    }

    public func record(isTunnel: Bool, bytesIn: Int64, bytesOut: Int64) {
        guard bytesIn > 0 || bytesOut > 0 else { return }
        lock.lock()
        if isTunnel {
            snapshot.tunnelBytesIn += max(0, bytesIn)
            snapshot.tunnelBytesOut += max(0, bytesOut)
        } else {
            snapshot.lanBytesIn += max(0, bytesIn)
            snapshot.lanBytesOut += max(0, bytesOut)
        }
        lock.unlock()
    }

    public var current: PitHubTrafficSnapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    public func reset() {
        lock.lock()
        snapshot = PitHubTrafficSnapshot()
        lock.unlock()
        persist()
    }

    public func persist() {
        guard let url = persistURL else { return }
        let value = current
        DispatchQueue.global(qos: .utility).async {
            do {
                try PitHubPaths.ensureDirectory(url.deletingLastPathComponent())
                let data = try JSONEncoder().encode(value)
                try data.write(to: url, options: .atomic)
            } catch {
                PitHubLog.error("流量统计保存失败：\(error.localizedDescription)")
            }
        }
    }

    public func jsonObject() -> [String: Any] {
        let value = current
        return [
            "lanIn": value.lanBytesIn,
            "lanOut": value.lanBytesOut,
            "tunnelIn": value.tunnelBytesIn,
            "tunnelOut": value.tunnelBytesOut,
            "totalIn": value.totalBytesIn,
            "totalOut": value.totalBytesOut,
            "total": value.totalBytes
        ]
    }
}
