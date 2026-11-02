//
//  PitHubExtensions.swift
//  PitHubCore
//
//  通用工具：日期格式、URL 编码、MIME、Cookie、JSON、路径安全。
//

import Foundation

// MARK: - 日期

public enum PitHubFormat {

    private static let lock = NSLock()
    private static let httpFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func httpDate(_ date: Date = Date()) -> String {
        lock.lock(); defer { lock.unlock() }
        return httpFormatter.string(from: date)
    }

    public static func iso(_ date: Date = Date()) -> String {
        lock.lock(); defer { lock.unlock() }
        return isoFormatter.string(from: date)
    }

    public static func isoFromSeconds(_ seconds: TimeInterval) -> String {
        iso(Date(timeIntervalSince1970: seconds))
    }

    public static func fileDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    public static func humanBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(max(0, bytes))
        var index = 0
        while value >= 1024 && index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == 0 { return "\(Int(value)) B" }
        return String(format: "%.1f %@", value, units[index])
    }
}

// MARK: - 字符串 / URL

public extension String {

    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    var htmlEscaped: String {
        var result = self
        result = result.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        result = result.replacingOccurrences(of: "'", with: "&#39;")
        return result
    }

    /// 对 URL 路径中的单段进行编码（保留中文，但转义 / ? # % 等）
    var urlPathEncoded: String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }

    var urlQueryEncoded: String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }

    /// 提取文件扩展名（小写，不含点）
    var pathExtensionLowercased: String { (self as NSString).pathExtension.lowercased() }

    /// 清理用户上传的文件名，防止目录穿越与控制字符
    var sanitizedFileName: String {
        let illegal = CharacterSet(charactersIn: "/\\:\0").union(.controlCharacters)
        var name = components(separatedBy: illegal).joined(separator: "_").trimmed
        if name.isEmpty { name = "unnamed" }
        if name.hasPrefix(".") { name = "_" + String(name.dropFirst()) }
        if name.count > 180 { name = String(name.prefix(180)) }
        return name
    }

    func containsAny(of values: [String]) -> Bool {
        values.contains { contains($0) }
    }
}

public extension Data {
    var utf8String: String { String(data: self, encoding: .utf8) ?? "" }

    mutating func appendUTF8(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}

// MARK: - MIME

public enum PitHubMIME {

    private static let mapping: [String: String] = [
        "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif",
        "webp": "image/webp", "heic": "image/heic", "heif": "image/heif", "bmp": "image/bmp",
        "tif": "image/tiff", "tiff": "image/tiff", "svg": "image/svg+xml",
        "mp4": "video/mp4", "mov": "video/quicktime", "m4v": "video/x-m4v",
        "avi": "video/x-msvideo", "mkv": "video/x-matroska", "webm": "video/webm",
        "mp3": "audio/mpeg", "m4a": "audio/mp4", "wav": "audio/wav", "aac": "audio/aac",
        "flac": "audio/flac", "ogg": "audio/ogg",
        "pdf": "application/pdf",
        "txt": "text/plain; charset=utf-8", "md": "text/markdown; charset=utf-8",
        "csv": "text/csv; charset=utf-8", "tsv": "text/tab-separated-values; charset=utf-8",
        "json": "application/json; charset=utf-8", "xml": "application/xml; charset=utf-8",
        "webmanifest": "application/manifest+json",
        "html": "text/html; charset=utf-8", "htm": "text/html; charset=utf-8",
        "css": "text/css; charset=utf-8", "js": "text/javascript; charset=utf-8",
        "mjs": "text/javascript; charset=utf-8",
        "zip": "application/zip", "gz": "application/gzip", "tar": "application/x-tar",
        "7z": "application/x-7z-compressed", "rar": "application/vnd.rar",
        "doc": "application/msword",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xls": "application/vnd.ms-excel",
        "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "ppt": "application/vnd.ms-powerpoint",
        "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "epub": "application/epub+zip",
        "rtf": "application/rtf",
        "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf",
        "ipa": "application/octet-stream",
        "plist": "application/x-plist"
    ]

    public static func type(for path: String) -> String {
        let ext = path.pathExtensionLowercased
        if let value = mapping[ext] { return value }
        if ext.isEmpty { return "application/octet-stream" }
        return "application/octet-stream"
    }

    public static func isText(_ path: String) -> Bool {
        let ext = path.pathExtensionLowercased
        return ["txt", "md", "csv", "tsv", "json", "xml", "html", "htm", "css", "js", "mjs", "log", "yml", "yaml", "ini", "conf", "swift", "py", "sh", "plist", "svg"].contains(ext)
    }

    public static func isImage(_ path: String) -> Bool {
        let ext = path.pathExtensionLowercased
        return ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff", "svg"].contains(ext)
    }

    public static func isVideo(_ path: String) -> Bool {
        let ext = path.pathExtensionLowercased
        return ["mp4", "mov", "m4v", "avi", "mkv", "webm"].contains(ext)
    }

    public static func kind(for path: String) -> String {
        let ext = path.pathExtensionLowercased
        if isImage(path) { return "image" }
        if isVideo(path) { return "video" }
        if ext == "pdf" { return "pdf" }
        if isText(path) { return "text" }
        if ["mp3", "m4a", "wav", "aac", "flac", "ogg"].contains(ext) { return "audio" }
        return "file"
    }
}

// MARK: - Cookie

public enum PitHubCookie {

    public static func parse(_ header: String?) -> [String: String] {
        guard let header, !header.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for part in header.split(separator: ";") {
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { continue }
            let key = pieces[0].trimmingCharacters(in: .whitespaces)
            let value = pieces[1].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = value.removingPercentEncoding ?? value }
        }
        return result
    }

    public static func setCookie(name: String, value: String, maxAge: Int, httpOnly: Bool = true, sameSite: String = "Lax") -> String {
        var parts = ["\(name)=\(value)", "Path=/", "Max-Age=\(maxAge)"]
        if httpOnly { parts.append("HttpOnly") }
        if !sameSite.isEmpty { parts.append("SameSite=\(sameSite)") }
        return parts.joined(separator: "; ")
    }

    public static func deleteCookie(name: String) -> String {
        "\(name)=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax"
    }
}

// MARK: - JSON

public enum PitHubJSON {

    public static func data(_ object: Any, pretty: Bool = false) -> Data {
        var options: JSONSerialization.WritingOptions = [.sortedKeys]
        if pretty { options.insert(.prettyPrinted) }
        if JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object, options: options) {
            return data
        }
        return Data("{}".utf8)
    }

    public static func string(_ object: Any) -> String {
        data(object).utf8String
    }

    public static func decodeDictionary(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    public static func readObject(at url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    public static func write(_ object: Any, to url: URL) throws {
        let data = data(object, pretty: true)
        try PitHubPaths.ensureDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - 路径安全

public enum PitHubPathGuard {

    /// 把 "a/b/../c" 这类路径规范化，并拒绝任何穿越意图。
    public static func normalizedRelativePath(_ raw: String) -> String? {
        let decoded = raw.removingPercentEncoding ?? raw
        let replaced = decoded.replacingOccurrences(of: "\\", with: "/")
        let parts = replaced.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var result: [String] = []
        for part in parts {
            if part == "." { continue }
            if part == ".." { return nil }
            if part.contains("\0") { return nil }
            result.append(part)
        }
        return result.joined(separator: "/")
    }

    public static func safeJoin(base: URL, relative: String) -> URL? {
        guard let normalized = normalizedRelativePath(relative) else { return nil }
        let url = base.appendingPathComponent(normalized, isDirectory: false)
        // 再次验证解析结果确实位于 base 内（防止编码绕过）
        let basePath = base.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path
        guard targetPath == basePath || targetPath.hasPrefix(basePath + "/") else { return nil }
        return url
    }

    public static func isSubpath(_ child: URL, of parent: URL) -> Bool {
        let p = parent.standardizedFileURL.path
        let c = child.standardizedFileURL.path
        return c == p || c.hasPrefix(p + "/")
    }
}
