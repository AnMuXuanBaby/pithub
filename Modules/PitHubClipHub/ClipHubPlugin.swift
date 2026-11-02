//
//  ClipHubPlugin.swift
//  PitHubClipHub
//
//  剪贴板中枢：文字/图片/文件剪贴记录，支持标签、搜索、保留上限。
//  所有数据保存在本机 Application Support/PitHub/ClipHub。
//

import Foundation
import PitHubCore

public struct ClipItem: Codable, Identifiable, Equatable {
    public var id: String
    public var kind: String          // text / image / file
    public var text: String
    public var filename: String
    public var mime: String
    public var tags: [String]
    public var createdAt: Date
    public var source: String
    public var size: Int64
    public var hasBlob: Bool

    public func jsonObject() -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "kind": kind,
            "text": text,
            "filename": filename,
            "mime": mime,
            "tags": tags,
            "createdAt": PitHubFormat.iso(createdAt),
            "source": source,
            "size": size,
            "hasBlob": hasBlob
        ]
        if hasBlob {
            dict["blobURL"] = "/api/clip/blob?id=\(id.urlQueryEncoded)"
        }
        return dict
    }
}

final class ClipHubStore {

    private let directory: URL
    private let indexURL: URL
    private let blobDirectory: URL
    private let lock = NSLock()
    private var items: [ClipItem] = []

    init(directory: URL, settings: PitHubSettings) throws {
        self.directory = directory
        self.indexURL = directory.appendingPathComponent("clips.json")
        self.blobDirectory = directory.appendingPathComponent("blobs", isDirectory: true)
        try PitHubPaths.ensureDirectory(directory)
        try PitHubPaths.ensureDirectory(blobDirectory)
        load()
        lock.lock()
        trimLocked(settings: settings)
        persistLocked()
        lock.unlock()
    }

    func add(text: String,
             kind: String,
             filename: String,
             mime: String,
             data: Data?,
             sourceFile: URL?,
             size: Int64,
             tags: [String],
             source: String,
             settings: PitHubSettings) throws -> ClipItem {
        let normalizedKind: String
        if kind == "text" || (data == nil && sourceFile == nil) {
            normalizedKind = "text"
        } else if kind == "image" || kind == "file" {
            normalizedKind = kind
        } else {
            normalizedKind = PitHubMIME.isImage(filename) ? "image" : "file"
        }

        let maxBytes = Int64(max(1, settings.clipHub.maxItemMB)) * 1024 * 1024
        if normalizedKind != "text" {
            guard size <= maxBytes else {
                throw FilePitErrorForClip.tooLarge("剪贴内容超过 \(settings.clipHub.maxItemMB) MB 上限")
            }
            guard data != nil || sourceFile != nil else {
                throw FilePitErrorForClip.invalid("缺少剪贴数据")
            }
        }

        let id = Self.randomToken(length: 20)
        let cleanName = filename.isEmpty ? (normalizedKind == "image" ? "clip-image.jpg" : "clip.bin") : filename.sanitizedFileName
        let cleanMime = mime.isEmpty ? PitHubMIME.type(for: cleanName) : mime
        let cleanTags = tags.map { $0.trimmed }.filter { !$0.isEmpty }.prefix(12).map { String($0) }

        var blobWritten = false
        if normalizedKind != "text" {
            let blobURL = blobDirectory.appendingPathComponent("\(id).bin")
            if let data {
                try data.write(to: blobURL, options: .atomic)
            } else if let sourceFile {
                try? FileManager.default.removeItem(at: blobURL)
                try FileManager.default.copyItem(at: sourceFile, to: blobURL)
            } else {
                throw FilePitErrorForClip.invalid("缺少剪贴数据")
            }
            blobWritten = true
        }

        let item = ClipItem(
            id: id,
            kind: normalizedKind,
            text: normalizedKind == "text" ? text : "",
            filename: normalizedKind == "text" ? "" : cleanName,
            mime: normalizedKind == "text" ? "text/plain" : cleanMime,
            tags: cleanTags,
            createdAt: Date(),
            source: source,
            size: normalizedKind == "text" ? Int64(text.utf8.count) : size,
            hasBlob: blobWritten
        )

        lock.lock()
        items.insert(item, at: 0)
        trimLocked(settings: settings)
        persistLocked()
        lock.unlock()
        return item
    }

    func list(query: String, tag: String, offset: Int, limit: Int) -> (items: [ClipItem], total: Int) {
        lock.lock()
        var filtered = items
        let trimmedQuery = query.trimmed
        if !trimmedQuery.isEmpty {
            filtered = filtered.filter { item in
                item.text.localizedCaseInsensitiveContains(trimmedQuery)
                    || item.filename.localizedCaseInsensitiveContains(trimmedQuery)
                    || item.tags.contains { $0.localizedCaseInsensitiveContains(trimmedQuery) }
            }
        }
        if !tag.isEmpty {
            filtered = filtered.filter { $0.tags.contains(tag) }
        }
        let total = filtered.count
        let start = max(0, offset)
        let safeLimit = max(1, min(limit, 200))
        if start >= filtered.count {
            filtered = []
        } else {
            filtered = Array(filtered[start..<min(filtered.count, start + safeLimit)])
        }
        lock.unlock()
        return (filtered, total)
    }

    func latest() -> ClipItem? {
        lock.lock(); defer { lock.unlock() }
        return items.first
    }

    func item(id: String) -> ClipItem? {
        lock.lock(); defer { lock.unlock() }
        return items.first { $0.id == id }
    }

    func blobURL(for item: ClipItem) -> URL? {
        guard item.hasBlob else { return nil }
        let url = blobDirectory.appendingPathComponent("\(item.id).bin")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func delete(id: String) throws {
        lock.lock()
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            throw FilePitErrorForClip.notFound("剪贴记录不存在")
        }
        let item = items.remove(at: index)
        persistLocked()
        lock.unlock()
        if item.hasBlob {
            try? FileManager.default.removeItem(at: blobDirectory.appendingPathComponent("\(item.id).bin"))
        }
    }

    func clear() {
        lock.lock()
        items.removeAll()
        persistLocked()
        lock.unlock()
        let fm = FileManager.default
        if let blobs = try? fm.contentsOfDirectory(at: blobDirectory, includingPropertiesForKeys: nil) {
            for blob in blobs { try? fm.removeItem(at: blob) }
        }
    }

    func tags() -> [(tag: String, count: Int)] {
        lock.lock(); defer { lock.unlock() }
        var counts: [String: Int] = [:]
        for item in items {
            for tag in item.tags { counts[tag, default: 0] += 1 }
        }
        return counts.map { ($0.key, $0.value) }.sorted { $0.count > $1.count }
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return items.count
    }

    // MARK: - 内部

    private func trimLocked(settings: PitHubSettings) {
        let maxRecords = max(10, settings.clipHub.maxRecords)
        let retention = max(1, settings.clipHub.retentionDays)
        let cutoff = Date().addingTimeInterval(-TimeInterval(retention * 24 * 3600))
        var removed: [ClipItem] = []

        if items.count > maxRecords {
            removed.append(contentsOf: items[maxRecords...])
            items = Array(items.prefix(maxRecords))
        }
        if let cutoffIndex = items.firstIndex(where: { $0.createdAt < cutoff }) {
            removed.append(contentsOf: items[cutoffIndex...])
            items = Array(items[..<cutoffIndex])
        }
        for item in removed where item.hasBlob {
            try? FileManager.default.removeItem(at: blobDirectory.appendingPathComponent("\(item.id).bin"))
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = (try? decoder.decode([ClipItem].self, from: data)) ?? []
    }

    private func persistLocked() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(items) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    private static func randomToken(length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var result = ""
        for _ in 0..<length {
            result.append(alphabet[Int.random(in: 0..<alphabet.count)])
        }
        return result
    }
}

enum FilePitErrorForClip: LocalizedError {
    case invalid(String)
    case tooLarge(String)
    case notFound(String)
    case forbidden(String)

    var status: Int {
        switch self {
        case .invalid: return 400
        case .tooLarge: return 413
        case .notFound: return 404
        case .forbidden: return 403
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalid(let message), .tooLarge(let message), .notFound(let message), .forbidden(let message):
            return message
        }
    }

    func response() -> HTTPResponse {
        .json(["ok": false, "error": errorDescription ?? "操作失败"], status: status)
    }
}

public final class ClipHubPlugin: PitHubPlugin {

    public var id: String { "clip" }
    public var displayName: String { "ClipHub" }
    public var summary: String { "剪贴板中枢 · 文本/图片/文件 · 标签与搜索" }
    public var systemImage: String { "doc.on.clipboard" }
    public var apiPrefix: String { "/api/clip" }
    public var extraPrefixes: [String] { [] }
    public var defaultEnabled: Bool { false }

    private weak var host: PitHubPluginHost?
    private var store: ClipHubStore?

    public init() {}

    public func attach(host: PitHubPluginHost, dataDirectory: URL) {
        self.host = host
        do {
            store = try ClipHubStore(directory: dataDirectory, settings: host.settingsSnapshot)
        } catch {
            PitHubLog.error("ClipHub 初始化失败：\(error.localizedDescription)")
        }
    }

    public func handle(_ request: HTTPRequest,
                       subPath: String,
                       context: PitHubPluginRequestContext,
                       respond: @escaping (HTTPResponse) -> Void) {
        guard let store else {
            respond(.error(503, "ClipHub 尚未就绪"))
            return
        }

        var route = subPath
        if route.hasPrefix("/") { route.removeFirst() }
        if route.hasSuffix("/") { route.removeLast() }

        do {
            switch route {
            case "push":
                guard request.method == "POST" else { respond(.error(405, "仅支持 POST")); return }
                guard context.role >= .user else { respond(.error(403, "访客不能写入剪贴板")); return }
                let dict = try requireJSON(request)
                let kind = dict["kind"] as? String ?? "text"
                let text = dict["text"] as? String ?? ""
                if kind == "text" && text.trimmed.isEmpty {
                    throw FilePitErrorForClip.invalid("剪贴文本不能为空")
                }
                var data: Data?
                if let base64 = dict["dataBase64"] as? String, !base64.isEmpty {
                    data = Data(base64Encoded: base64)
                    if data == nil { throw FilePitErrorForClip.invalid("dataBase64 解码失败") }
                }
                if kind != "text" && data == nil {
                    throw FilePitErrorForClip.invalid("图片/文件剪贴需要提供 dataBase64 或使用 /api/clip/blob 上传")
                }
                let maxBytes = Int64(max(1, context.settings.clipHub.maxItemMB)) * 1024 * 1024
                let estimatedSize = Int64(data?.count ?? 0)
                guard estimatedSize <= maxBytes else { throw FilePitErrorForClip.tooLarge("剪贴内容过大") }
                let item = try store.add(
                    text: text,
                    kind: kind,
                    filename: dict["filename"] as? String ?? "",
                    mime: dict["mime"] as? String ?? "",
                    data: data,
                    sourceFile: nil,
                    size: estimatedSize,
                    tags: stringList(dict["tags"]),
                    source: dict["source"] as? String ?? request.remoteAddress,
                    settings: context.settings
                )
                respond(.json(["ok": true, "item": item.jsonObject()]))

            case "blob" where request.method == "POST":
                guard context.role >= .user else { respond(.error(403, "访客不能写入剪贴板")); return }
                guard !request.contentType.lowercased().hasPrefix("multipart/") else {
                    respond(.error(415, "请使用原始二进制上传"));
                    return
                }
                let filename = request.query["filename"] ?? "clip.bin"
                let kind = request.query["kind"] ?? (PitHubMIME.isImage(filename) ? "image" : "file")
                let item = try store.add(
                    text: "",
                    kind: kind,
                    filename: filename,
                    mime: request.query["mime"] ?? PitHubMIME.type(for: filename),
                    data: request.bodyFileURL == nil ? request.body : nil,
                    sourceFile: request.bodyFileURL,
                    size: request.bodySize,
                    tags: stringList(request.query["tags"]),
                    source: request.remoteAddress,
                    settings: context.settings
                )
                respond(.json(["ok": true, "item": item.jsonObject()]))

            case "latest":
                guard request.method == "GET" else { respond(.error(405, "仅支持 GET")); return }
                if let item = store.latest() {
                    respond(.json(["ok": true, "item": item.jsonObject()]))
                } else {
                    respond(.json(["ok": true, "item": NSNull()]))
                }

            case "list":
                guard request.method == "GET" else { respond(.error(405, "仅支持 GET")); return }
                let query = request.query["q"] ?? ""
                let tag = request.query["tag"] ?? ""
                let offset = Int(request.query["offset"] ?? "0") ?? 0
                let limit = Int(request.query["limit"] ?? "50") ?? 50
                let page = store.list(query: query, tag: tag, offset: offset, limit: limit)
                respond(.json([
                    "ok": true,
                    "total": page.total,
                    "offset": offset,
                    "limit": limit,
                    "items": page.items.map { $0.jsonObject() }
                ]))

            case "get":
                guard let id = request.query["id"], let item = store.item(id: id) else {
                    respond(.error(404, "记录不存在")); return
                }
                respond(.json(["ok": true, "item": item.jsonObject()]))

            case "blob":
                guard request.method == "GET" else { respond(.error(405, "仅支持 GET")); return }
                guard let id = request.query["id"], let item = store.item(id: id),
                      let url = store.blobURL(for: item) else {
                    respond(.error(404, "剪贴内容不存在")); return
                }
                var response = HTTPResponse.file(
                    url: url,
                    contentType: item.mime,
                    downloadName: item.filename,
                    inline: true,
                    supportsRange: true,
                    action: "clip-blob"
                )
                response.headers["Cache-Control"] = "private, max-age=3600"
                respond(response)

            case "delete":
                guard context.role >= .user else { respond(.error(403, "需要登录权限")); return }
                guard request.method == "POST" || request.method == "DELETE" else {
                    respond(.error(405, "仅支持 POST/DELETE")); return
                }
                var id = request.query["id"]
                if id == nil {
                    if let dict = try? requireJSON(request) { id = dict["id"] as? String }
                }
                guard let resolved = id, !resolved.isEmpty else {
                    respond(.error(400, "缺少 id")); return
                }
                try store.delete(id: resolved)
                respond(.json(["ok": true]))

            case "clear":
                guard context.role >= .user else { respond(.error(403, "需要登录权限")); return }
                guard request.method == "POST" else { respond(.error(405, "仅支持 POST")); return }
                store.clear()
                respond(.json(["ok": true]))

            case "tags":
                guard request.method == "GET" else { respond(.error(405, "仅支持 GET")); return }
                respond(.json([
                    "ok": true,
                    "tags": store.tags().map { ["tag": $0.tag, "count": $0.count] }
                ]))

            case "status":
                respond(.json([
                    "ok": true,
                    "count": store.count,
                    "maxRecords": context.role == .guest ? 0 : context.settings.clipHub.maxRecords
                ]))

            default:
                respond(.error(404, "未实现的 ClipHub 接口：\(route)"))
            }
        } catch let error as FilePitErrorForClip {
            respond(error.response())
        } catch {
            respond(.error(500, error.localizedDescription))
        }
    }

    // MARK: - 本机预览

    public func nativeItems(limit: Int = 50) -> [ClipItem] {
        guard let store else { return [] }
        return store.list(query: "", tag: "", offset: 0, limit: limit).items
    }

    public func nativePushText(_ text: String) -> Bool {
        guard let store, let host, !text.isEmpty else { return false }
        let item = try? store.add(text: text, kind: "text", filename: "", mime: "text/plain",
                                  data: nil, sourceFile: nil, size: Int64(text.utf8.count), tags: [],
                                  source: "app", settings: host.settingsSnapshot)
        return item != nil
    }

    public func nativeDelete(id: String) {
        try? store?.delete(id: id)
    }

    private func requireJSON(_ request: HTTPRequest) throws -> [String: Any] {
        guard let data = request.bodyData(maxBytes: 32 * 1024 * 1024),
              let dict = PitHubJSON.decodeDictionary(data) else {
            throw FilePitErrorForClip.invalid("请求体不是有效的 JSON")
        }
        return dict
    }

    private func stringList(_ value: Any?) -> [String] {
        if let array = value as? [String] {
            return array.map { $0.trimmed }.filter { !$0.isEmpty }
        }
        if let string = value as? String {
            return string.split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty }
        }
        return []
    }
}
