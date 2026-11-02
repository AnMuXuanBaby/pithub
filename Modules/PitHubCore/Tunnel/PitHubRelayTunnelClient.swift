//
//  PitHubRelayTunnelClient.swift
//  PitHubCore
//
//  PitHub Relay 隧道客户端（WebSocket）。配合仓库里的 relay/server.mjs 使用：
//  iPhone 主动连接 relay（不需要公网 IP），relay 分配一个公网地址并把
//  公网 HTTP 请求转发进来。
//
//  协议（JSON over WebSocket）：
//   server -> phone : {"type":"ready","url":"https://relay/t/xxx/"}
//   server -> phone : {"type":"request","id":"..","method":"GET","path":"/api/status",
//                      "headers":{..},"body":"<base64>","remote":"1.2.3.4"}
//   phone  -> server: {"type":"response","id":"..","status":200,"headers":{..},"body":"<base64>"}
//   heartbeat       : {"type":"ping"} / {"type":"pong"}
//
//  限制：单次响应体会被 base64 内联，建议控制在 24MB 以内；
//  大文件请走 Range 分片（浏览器/播放器会自动这么做）。文档中已标注。
//

import Foundation

final class PitHubRelayTunnelClient: NSObject {

    typealias RequestHandler = (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void

    var onReady: ((String) -> Void)?
    var onStateChange: ((String?) -> Void)?
    var onRequest: RequestHandler?

    private let relayURL: URL
    private let token: String
    private let name: String

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var heartbeatTimer: DispatchSourceTimer?
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectAttempt = 0
    private var isStopped = false
    private var lastPong = Date()
    private let maxInlineBody = 24 * 1024 * 1024

    init(relayURL: URL, token: String, name: String) {
        self.relayURL = relayURL
        self.token = token
        self.name = name
        super.init()
    }

    // MARK: - 生命周期

    func start() {
        isStopped = false
        connect()
    }

    func stop() {
        isStopped = true
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func connect() {
        guard !isStopped else { return }
        onStateChange?("正在连接 Relay…")

        guard var components = URLComponents(url: relayURL, resolvingAgainstBaseURL: false) else {
            onStateChange?("Relay 地址无效")
            return
        }
        if components.scheme == "https" { components.scheme = "wss" }
        if components.scheme == "http" { components.scheme = "ws" }
        if components.path.isEmpty || components.path == "/" {
            components.path = "/tunnel"
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "token", value: token))
        items.append(URLQueryItem(name: "name", value: name))
        components.queryItems = items

        guard let url = components.url else {
            onStateChange?("Relay 地址无效")
            return
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = true
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session

        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()

        lastPong = Date()
        startHeartbeat()
        receiveLoop()
    }

    private func startHeartbeat() {
        heartbeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in
            guard let self, !self.isStopped else { return }
            if Date().timeIntervalSince(self.lastPong) > 90 {
                self.onStateChange?("Relay 心跳超时，正在重连…")
                self.task?.cancel(with: .goingAway, reason: nil)
                return
            }
            self.sendJSON(["type": "ping"])
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func scheduleReconnect() {
        guard !isStopped else { return }
        reconnectAttempt += 1
        let delay = min(30.0, pow(2.0, Double(min(reconnectAttempt, 5))))
        onStateChange?("连接断开，\(Int(delay)) 秒后重连（第 \(reconnectAttempt) 次）")

        reconnectWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopped else { return }
            self.session?.invalidateAndCancel()
            self.session = nil
            self.task = nil
            self.connect()
        }
        reconnectWorkItem = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: - 收发

    private func receiveLoop() {
        guard let task, !isStopped else { return }
        task.receive { [weak self] result in
            guard let self, !self.isStopped else { return }
            switch result {
            case .failure(let error):
                PitHubLog.error("Relay WebSocket 断开：\(error.localizedDescription)")
                self.onStateChange?("Relay 连接异常：\(error.localizedDescription)")
                self.scheduleReconnect()
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                self.receiveLoop()
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let rawObject = try? JSONSerialization.jsonObject(with: data),
              let object = rawObject as? [String: Any],
              let type = object["type"] as? String else {
            return
        }

        switch type {
        case "ready":
            lastPong = Date()
            if let url = object["url"] as? String {
                onReady?(url)
            } else {
                onReady?("")
            }
            onStateChange?(nil)
        case "pong":
            lastPong = Date()
        case "ping":
            sendJSON(["type": "pong"])
        case "request":
            handleRelayRequest(object)
        case "error":
            onStateChange?(object["message"] as? String ?? "Relay 返回错误")
        default:
            break
        }
    }

    private func handleRelayRequest(_ object: [String: Any]) {
        guard let id = object["id"] as? String,
              let method = object["method"] as? String,
              let path = object["path"] as? String else { return }

        let headers = (object["headers"] as? [String: String]) ?? [:]
        let bodyString = object["body"] as? String ?? ""
        let bodyData = bodyString.isEmpty ? Data() : (Data(base64Encoded: bodyString) ?? Data())
        let remote = object["remote"] as? String
            ?? headers["x-forwarded-for"]?.split(separator: ",").first.map(String.init)
            ?? "relay"

        var requestHeaders = headers
        requestHeaders["x-pithub-tunnel"] = "1"
        requestHeaders["x-pithub-transport"] = "relay"

        let query = Self.parseQuery(path)
        let rawPath = path.split(separator: "?").first.map(String.init) ?? path
        let request = HTTPRequest(
            method: method.uppercased(),
            rawPath: rawPath,
            path: rawPath.removingPercentEncoding ?? rawPath,
            query: query,
            headers: requestHeaders,
            body: bodyData,
            bodyFileURL: nil,
            bodySize: Int64(bodyData.count),
            remoteAddress: remote.trimmingCharacters(in: .whitespaces),
            isTunnel: true,
            isLocalConnection: false,
            cookies: PitHubCookie.parse(headers["cookie"])
        )

        guard let onRequest else {
            sendResponse(id: id, response: .error(503, "本地服务未就绪"), request: request)
            return
        }
        onRequest(request) { [weak self] response in
            self?.sendResponse(id: id, response: response, request: request)
        }
    }

    private func sendResponse(id: String, response: HTTPResponse, request: HTTPRequest) {
        var headers = response.headers
        headers.removeValue(forKey: "Content-Length")
        headers.removeValue(forKey: "Connection")
        headers.removeValue(forKey: "Transfer-Encoding")
        headers.removeValue(forKey: "Date")
        headers.removeValue(forKey: "Server")

        var status = response.status
        var data = Data()

        func fail(_ status: Int, _ message: String) {
            sendJSON([
                "type": "response", "id": id, "status": status,
                "headers": ["Content-Type": "application/json; charset=utf-8"],
                "body": Self.base64(Data("{\"ok\":false,\"error\":\"\(message)\"}".utf8))
            ])
        }

        switch response.body {
        case .empty:
            sendJSON(["type": "response", "id": id, "status": status, "headers": headers, "body": ""])
            return

        case .data(let value):
            data = value
            if response.supportsRange, let rawRange = request.header("range"), !value.isEmpty {
                switch Self.parseRange(rawRange, size: Int64(value.count)) {
                case .valid(let offset, let length):
                    status = 206
                    data = value.subdata(in: Int(offset)..<Int(offset + length))
                    headers["Content-Range"] = "bytes \(offset)-\(offset + length - 1)/\(value.count)"
                case .unsatisfiable:
                    fail(416, "请求范围无效")
                    return
                case .none:
                    break
                }
            }

        case .file(let url):
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            if response.cleanupFileAfterSend { defer { try? FileManager.default.removeItem(at: url) } }

            var offset: Int64 = 0
            var length = fileSize
            if response.supportsRange, let rawRange = request.header("range") {
                switch Self.parseRange(rawRange, size: fileSize) {
                case .valid(let start, let len):
                    offset = start
                    length = len
                    status = 206
                    headers["Content-Range"] = "bytes \(start)-\(start + len - 1)/\(fileSize)"
                case .unsatisfiable:
                    fail(416, "请求范围无效")
                    return
                case .none:
                    break
                }
            }

            guard let read = Self.readFile(url, offset: offset, length: length) else {
                fail(404, "文件不存在或读取失败")
                return
            }
            data = read
        }

        if data.count > maxInlineBody {
            fail(413, "通过 Relay 传输的响应体超过 24MB，请使用 Range 请求或分片下载")
            return
        }
        if request.method == "HEAD" {
            data = Data()
        }
        sendJSON([
            "type": "response", "id": id, "status": status,
            "headers": headers, "body": Self.base64(data)
        ])
    }

    private enum RelayRange {
        case none
        case valid(offset: Int64, length: Int64)
        case unsatisfiable
    }

    private static func parseRange(_ header: String, size: Int64) -> RelayRange {
        let value = header.trimmingCharacters(in: .whitespaces)
        guard value.lowercased().hasPrefix("bytes=") else { return .none }
        let spec = String(value.dropFirst(6)).split(separator: ",").first.map(String.init) ?? ""
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return .unsatisfiable }
        let startText = parts[0].trimmingCharacters(in: .whitespaces)
        let endText = parts[1].trimmingCharacters(in: .whitespaces)
        if startText.isEmpty {
            guard let suffix = Int64(endText), suffix > 0, size > 0 else { return .unsatisfiable }
            let length = min(suffix, size)
            return .valid(offset: size - length, length: length)
        }
        guard let start = Int64(startText), start >= 0, start < size else { return .unsatisfiable }
        let end: Int64
        if endText.isEmpty {
            end = size - 1
        } else {
            guard let parsed = Int64(endText), parsed >= start else { return .unsatisfiable }
            end = min(parsed, size - 1)
        }
        return .valid(offset: start, length: end - start + 1)
    }

    private static func readFile(_ url: URL, offset: Int64, length: Int64) -> Data? {
        guard length >= 0 else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(max(0, offset)))
            var remaining = length
            var result = Data()
            result.reserveCapacity(Int(min(length, Int64(1024 * 1024))))
            while remaining > 0 {
                let chunkSize = Int(min(Int64(1024 * 1024), remaining))
                guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
                result.append(chunk)
                remaining -= Int64(chunk.count)
            }
            return result
        } catch {
            return nil
        }
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let task, !isStopped else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        task.send(.data(data)) { [weak self] error in
            if let error {
                PitHubLog.error("Relay 发送失败：\(error.localizedDescription)")
                self?.onStateChange?("Relay 发送失败：\(error.localizedDescription)")
            }
        }
    }

    private static func parseQuery(_ path: String) -> [String: String] {
        guard let question = path.firstIndex(of: "?") else { return [:] }
        let raw = String(path[path.index(after: question)...])
        var result: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            let value = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? String(parts[1])) : ""
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    private static func base64(_ data: Data) -> String {
        data.base64EncodedString()
    }
}

extension PitHubRelayTunnelClient: URLSessionWebSocketDelegate {

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        reconnectAttempt = 0
        lastPong = Date()
        onStateChange?("Relay 已连接，等待分配公网地址…")
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        guard !isStopped else { return }
        onStateChange?("Relay 连接已关闭（\(closeCode.rawValue)）")
        scheduleReconnect()
    }
}
