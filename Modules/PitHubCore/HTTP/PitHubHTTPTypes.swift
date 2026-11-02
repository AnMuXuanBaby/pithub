//
//  PitHubHTTPTypes.swift
//  PitHubCore
//
//  自研 HTTP/1.1 请求/响应模型。响应体支持 Data 与文件流，
//  文件响应默认支持 Range（由连接层统一处理 206）。
//

import Foundation

public struct HTTPRequest {

    public let method: String
    public let rawPath: String
    public let path: String
    public let query: [String: String]
    public let headers: [String: String]
    public let body: Data
    public let bodyFileURL: URL?
    public let bodySize: Int64
    public let remoteAddress: String
    public let isTunnel: Bool
    public let isLocalConnection: Bool
    public let cookies: [String: String]

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    public func queryValue(_ name: String) -> String? {
        query[name]
    }

    public func bodyData(maxBytes: Int = 32 * 1024 * 1024) -> Data? {
        if !body.isEmpty { return body }
        guard let url = bodyFileURL else { return Data() }
        guard bodySize <= Int64(maxBytes) else { return nil }
        return try? Data(contentsOf: url)
    }

    public var contentType: String {
        header("content-type") ?? ""
    }

    public var userAgent: String {
        header("user-agent") ?? "-"
    }
}

public enum HTTPResponseBody {
    case empty
    case data(Data)
    case file(URL)
}

public struct HTTPResponse {

    public var status: Int
    public var headers: [String: String]
    public var body: HTTPResponseBody
    public var supportsRange: Bool
    public var cleanupFileAfterSend: Bool
    /// 用于访问日志的简短操作名，例如 "download"、"upload"、"mkdir"
    public var logAction: String?

    public init(status: Int = 200,
                headers: [String: String] = [:],
                body: HTTPResponseBody = .empty,
                supportsRange: Bool = false,
                cleanupFileAfterSend: Bool = false,
                logAction: String? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
        self.supportsRange = supportsRange
        self.cleanupFileAfterSend = cleanupFileAfterSend
        self.logAction = logAction
    }

    // MARK: - 便捷构造

    public static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        var allHeaders = headers
        allHeaders["Content-Type"] = "application/json; charset=utf-8"
        return HTTPResponse(status: status, headers: allHeaders, body: .data(PitHubJSON.data(object)))
    }

    public static func jsonEncodable<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status,
                     headers: ["Content-Type": "application/json; charset=utf-8"],
                     body: .data(PitHubJSON.encode(value)))
    }

    public static func text(_ text: String, status: Int = 200, contentType: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": contentType], body: .data(Data(text.utf8)))
    }

    public static func html(_ html: String, status: Int = 200) -> HTTPResponse {
        text(html, status: status, contentType: "text/html; charset=utf-8")
    }

    public static func error(_ status: Int, _ message: String) -> HTTPResponse {
        var response = HTTPResponse.json(["ok": false, "error": message], status: status)
        response.logAction = "error"
        return response
    }

    public static func redirect(_ location: String, status: Int = 302) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Location": location], body: .empty)
    }

    public static func file(url: URL,
                            contentType: String? = nil,
                            downloadName: String? = nil,
                            inline: Bool = false,
                            supportsRange: Bool = true,
                            cleanup: Bool = false,
                            action: String? = "download") -> HTTPResponse {
        var headers: [String: String] = [:]
        headers["Content-Type"] = contentType ?? PitHubMIME.type(for: url.lastPathComponent)
        if let downloadName {
            let fallback = downloadName
                .replacingOccurrences(of: "\"", with: "_")
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: "")
            let encoded = downloadName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? downloadName
            let disposition = inline ? "inline" : "attachment"
            headers["Content-Disposition"] = "\(disposition); filename=\"\(fallback)\"; filename*=UTF-8''\(encoded)"
        }
        return HTTPResponse(status: 200, headers: headers, body: .file(url),
                            supportsRange: supportsRange, cleanupFileAfterSend: cleanup,
                            logAction: action)
    }
}

public enum PitHubHTTPStatusText {

    public static func text(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 207: return "Multi-Status"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 412: return "Precondition Failed"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 416: return "Range Not Satisfiable"
        case 423: return "Locked"
        case 424: return "Failed Dependency"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        case 507: return "Insufficient Storage"
        default: return "Status"
        }
    }
}

/// 连接层解析出来的请求头
struct HTTPRequestHead {
    let method: String
    let target: String
    let version: String
    let headers: [String: String]
    let path: String
    let rawPath: String
    let query: [String: String]
    let contentLength: Int64
    let isChunked: Bool
    let expectsContinue: Bool
    let headByteCount: Int64

    static func parse(headData: Data) -> HTTPRequestHead? {
        guard let text = String(data: headData, encoding: .utf8) else { return nil }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first, !requestLine.isEmpty else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0]).uppercased()
        var target = String(parts[1])
        let version = parts.count > 2 ? String(parts[2]) : "HTTP/1.1"

        // 处理 absolute-form：GET http://host/path HTTP/1.1
        if target.contains("://"), let url = URL(string: target) {
            let path = url.path.isEmpty ? "/" : url.path
            target = path + (url.query.map { "?" + $0 } ?? "")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, headers[name] == nil { headers[name] = value }
        }

        let splitIndex = target.firstIndex(of: "?")
        let rawPath = splitIndex == nil ? target : String(target[..<splitIndex!])
        let rawQuery = splitIndex == nil ? "" : String(target[target.index(after: splitIndex!)...])
        let decodedPath = rawPath.removingPercentEncoding ?? rawPath
        let query = parseQuery(rawQuery)

        let contentLength = Int64((headers["content-length"] ?? "0").trimmingCharacters(in: .whitespaces)) ?? 0
        let isChunked = (headers["transfer-encoding"]?.lowercased().contains("chunked") ?? false)
        let expectsContinue = headers["expect"]?.lowercased().contains("100-continue") ?? false

        return HTTPRequestHead(
            method: method,
            target: target,
            version: version,
            headers: headers,
            path: decodedPath,
            rawPath: rawPath,
            query: query,
            contentLength: contentLength,
            isChunked: isChunked,
            expectsContinue: expectsContinue,
            headByteCount: Int64(headData.count + 4)
        )
    }

    private static func parseQuery(_ raw: String) -> [String: String] {
        guard !raw.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let rawKey = String(parts[0]).replacingOccurrences(of: "+", with: " ")
            let rawValue = parts.count > 1 ? String(parts[1]).replacingOccurrences(of: "+", with: " ") : ""
            let key = rawKey.removingPercentEncoding ?? rawKey
            let value = rawValue.removingPercentEncoding ?? rawValue
            if !key.isEmpty, result[key] == nil { result[key] = value }
        }
        return result
    }
}
