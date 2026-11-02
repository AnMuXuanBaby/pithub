//
//  PitHubHTTPConnection.swift
//  PitHubCore
//
//  HTTP/1.1 连接状态机：
//  - 头部最多 64KB；
//  - 请求体超过 1MB 自动落盘，避免大文件上传时内存爆炸；
//  - 支持 Content-Length 与 chunked；
//  - 响应体支持文件流式发送 + Range（206）；
//  - 每个连接只处理一个请求，响应后关闭（Connection: close）。
//

import Foundation
import Network

final class PitHubHTTPConnection {

    let id = UUID()
    private let connection: NWConnection
    private let queue: DispatchQueue
    private weak var server: PitHubHTTPServer?

    var onRequest: ((HTTPRequest, PitHubHTTPConnection) -> Void)?

    private var requestHead: HTTPRequestHead?
    private var headBuffer = Data()
    private var bodyBuffer = Data()
    private var spoolURL: URL?
    private var spoolHandle: FileHandle?
    private var expectedBodyLength: Int64 = 0
    private var receivedBodyLength: Int64 = 0
    private var chunkBuffer = Data()
    private var chunkRemaining: Int64 = 0
    private var awaitingChunkTerminator = false
    private var isChunked = false
    private var requestCompleted = false
    private var responseSent = false
    private var didFinish = false
    private var currentRequest: HTTPRequest?
    private var cleanupFileURL: URL?
    private var bytesOut: Int64 = 0
    private var timeoutWorkItem: DispatchWorkItem?

    private let memoryBodyThreshold: Int64 = 1 * 1024 * 1024
    private let maxHeaderBytes = 64 * 1024

    init(connection: NWConnection, queue: DispatchQueue, server: PitHubHTTPServer) {
        self.connection = connection
        self.queue = queue
        self.server = server
    }

    // MARK: - 生命周期

    func start() {
        scheduleTimeout()
        receiveNext()
    }

    private func scheduleTimeout() {
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.didFinish else { return }
            if !self.responseSent {
                self.sendSimpleError(status: 504)
            }
        }
        timeoutWorkItem = item
        queue.asyncAfter(deadline: .now() + 180, execute: item)
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.didFinish else { return }
            if let error {
                PitHubLog.error("连接读取失败：\(error.localizedDescription)")
                self.cancel()
                return
            }
            if let data, !data.isEmpty {
                self.consume(data)
            }
            if isComplete {
                if !self.requestCompleted {
                    self.cancel()
                }
                return
            }
            if !self.requestCompleted {
                self.receiveNext()
            }
        }
    }

    private func consume(_ data: Data) {
        if requestHead == nil {
            headBuffer.append(data)
            guard let delimiter = headBuffer.range(of: Data("\r\n\r\n".utf8)) else {
                if headBuffer.count > maxHeaderBytes {
                    sendSimpleError(status: 431)
                }
                return
            }
            let headData = headBuffer.subdata(in: headBuffer.startIndex..<delimiter.lowerBound)
            let rest = headBuffer.subdata(in: delimiter.upperBound..<headBuffer.endIndex)
            headBuffer = Data()

            guard let head = HTTPRequestHead.parse(headData: headData) else {
                sendSimpleError(status: 400)
                return
            }
            requestHead = head
            isChunked = head.isChunked

            if head.expectsContinue {
                let interim = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)
                connection.send(content: interim, completion: .contentProcessed { _ in })
            }

            if isChunked {
                prepareSpool()
            } else if head.contentLength > memoryBodyThreshold {
                prepareSpool()
            }
            expectedBodyLength = head.contentLength

            if isChunked {
                feedChunked(rest)
            } else if expectedBodyLength > 0 {
                feedBody(rest)
            } else {
                completeRequest()
            }
        } else if requestCompleted {
            return
        } else if isChunked {
            feedChunked(data)
        } else {
            feedBody(data)
        }
    }

    // MARK: - 请求体

    private func prepareSpool() {
        guard spoolURL == nil else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pithub-body-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        spoolURL = url
        spoolHandle = try? FileHandle(forWritingTo: url)
    }

    private func appendBody(_ data: Data) {
        guard !data.isEmpty else { return }
        receivedBodyLength += Int64(data.count)
        if let handle = spoolHandle {
            do {
                try handle.write(contentsOf: data)
            } catch {
                PitHubLog.error("请求体写入临时文件失败：\(error.localizedDescription)")
            }
        } else {
            bodyBuffer.append(data)
        }
    }

    private func feedBody(_ data: Data) {
        guard !requestCompleted else { return }
        var remainingData = data
        if expectedBodyLength > 0 {
            let remainingBytes = expectedBodyLength - receivedBodyLength
            if remainingBytes > 0 {
                let take = min(remainingData.count, Int(remainingBytes))
                let slice = remainingData.prefix(take)
                appendBody(Data(slice))
                remainingData.removeFirst(take)
            }
        } else {
            appendBody(remainingData)
            remainingData.removeAll()
        }
        if !isChunked, receivedBodyLength >= expectedBodyLength {
            completeRequest()
        }
    }

    private func feedChunked(_ data: Data) {
        chunkBuffer.append(data)
        while true {
            if awaitingChunkTerminator {
                guard chunkBuffer.count >= 2 else { return }
                chunkBuffer.removeFirst(2)
                awaitingChunkTerminator = false
            }
            if chunkRemaining > 0 {
                let take = min(Int(chunkRemaining), chunkBuffer.count)
                if take == 0 { return }
                let slice = chunkBuffer.prefix(take)
                appendBody(Data(slice))
                chunkBuffer.removeFirst(take)
                chunkRemaining -= Int64(take)
                if chunkRemaining == 0 { awaitingChunkTerminator = true }
                continue
            }
            guard let crlf = chunkBuffer.range(of: Data("\r\n".utf8)) else { return }
            let lineData = chunkBuffer.subdata(in: chunkBuffer.startIndex..<crlf.lowerBound)
            chunkBuffer.removeSubrange(chunkBuffer.startIndex..<crlf.upperBound)
            let line = String(data: lineData, encoding: .utf8) ?? "0"
            let sizePart = line.split(separator: ";").first.map(String.init) ?? "0"
            guard let size = Int64(sizePart.trimmingCharacters(in: .whitespaces)), size >= 0 else {
                sendSimpleError(status: 400)
                return
            }
            if size == 0 {
                completeRequest()
                return
            }
            chunkRemaining = size
        }
    }

    // MARK: - 完成请求

    private func completeRequest() {
        guard !requestCompleted, let head = requestHead else { return }
        requestCompleted = true
        timeoutWorkItem?.cancel()

        var body = bodyBuffer
        if let url = spoolURL {
            let total = receivedBodyLength
            if total <= memoryBodyThreshold, let data = try? Data(contentsOf: url) {
                body = data
                try? spoolHandle?.close()
                spoolHandle = nil
                try? FileManager.default.removeItem(at: url)
                spoolURL = nil
            } else {
                try? spoolHandle?.close()
                spoolHandle = nil
            }
        }

        let remoteIP = extractRemoteIP(head.headers)
        let isTunnel = head.headers["x-pithub-tunnel"]?.lowercased() == "1"
            || head.headers["cf-connecting-ip"] != nil
            || head.headers["x-forwarded-for"] != nil

        let cookies = PitHubCookie.parse(head.headers["cookie"])

        let request = HTTPRequest(
            method: head.method,
            rawPath: head.rawPath,
            path: head.path,
            query: head.query,
            headers: head.headers,
            body: body,
            bodyFileURL: spoolURL,
            bodySize: receivedBodyLength,
            remoteAddress: remoteIP,
            isTunnel: isTunnel,
            isLocalConnection: !isTunnel,
            cookies: cookies
        )
        currentRequest = request

        server?.recordTraffic(isTunnel: isTunnel, bytesIn: head.headByteCount + receivedBodyLength, bytesOut: 0)

        if let onRequest {
            onRequest(request, self)
        } else {
            send(.error(503, "服务尚未就绪"))
        }
    }

    private func extractRemoteIP(_ headers: [String: String]) -> String {
        if let forwarded = headers["x-forwarded-for"]?.split(separator: ",").first {
            return forwarded.trimmingCharacters(in: .whitespaces)
        }
        if let cf = headers["cf-connecting-ip"], !cf.isEmpty { return cf }
        switch connection.endpoint {
        case .hostPort(let host, _):
            return "\(host)"
        default:
            return "unknown"
        }
    }

    // MARK: - 发送响应

    func send(_ response: HTTPResponse) {
        guard !responseSent else { return }
        responseSent = true

        if case .file(let url) = response.body, response.cleanupFileAfterSend {
            cleanupFileURL = url
        }

        var headers = response.headers
        var status = response.status
        var contentLength: Int64 = 0
        var fileOffset: Int64 = 0
        var isFile = false
        var fileURL: URL?

        switch response.body {
        case .empty:
            contentLength = 0
        case .data(let data):
            contentLength = Int64(data.count)
        case .file(let url):
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attributes[.size] as? NSNumber)?.int64Value else {
                responseSent = false
                sendSimpleError(status: 404)
                return
            }
            isFile = true
            fileURL = url
            contentLength = size
            if response.supportsRange, let rawRange = currentRequest?.header("range") {
                switch Self.parseRange(rawRange, size: size) {
                case .none:
                    break
                case .unsatisfiable:
                    sendRangeNotSatisfiable(size: size, headers: headers)
                    return
                case .valid(let offset, let length):
                    status = 206
                    fileOffset = offset
                    contentLength = length
                    headers["Content-Range"] = "bytes \(offset)-\(offset + length - 1)/\(size)"
                }
            }
            if headers["Content-Type"] == nil {
                headers["Content-Type"] = PitHubMIME.type(for: url.lastPathComponent)
            }
        }

        if status == 204 || status == 304 {
            contentLength = 0
        }

        headers["Content-Length"] = String(contentLength)
        headers["Server"] = "PitHub/1.0"
        headers["Date"] = PitHubFormat.httpDate()
        headers["Connection"] = "close"
        if response.supportsRange, isFile {
            headers["Accept-Ranges"] = "bytes"
        }

        var lines = ["HTTP/1.1 \(status) \(PitHubHTTPStatusText.text(for: status))"]
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            let cleanName = name.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            let cleanValue = value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            lines.append("\(cleanName): \(cleanValue)")
        }
        let headData = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)

        connection.send(content: headData, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil { self.cancel(); return }
            self.bytesOut += Int64(headData.count)

            let isHeadRequest = self.currentRequest?.method == "HEAD"
            if isHeadRequest || contentLength == 0 {
                self.finish()
                return
            }

            switch response.body {
            case .data(let data):
                self.sendDataBody(data)
            case .file:
                if let fileURL {
                    self.streamFile(fileURL, offset: fileOffset, length: contentLength)
                } else {
                    self.finish()
                }
            case .empty:
                self.finish()
            }
        })
    }

    private func sendDataBody(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil { self.cancel(); return }
            self.bytesOut += Int64(data.count)
            self.flushTraffic()
            self.finish()
        })
    }

    private func streamFile(_ url: URL, offset: Int64, length: Int64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            finish()
            return
        }
        do {
            try handle.seek(toOffset: UInt64(max(0, offset)))
        } catch {
            try? handle.close()
            finish()
            return
        }

        var remaining = length
        let isTunnel = currentRequest?.isTunnel ?? false
        let rateKBps = server?.rateLimitKBps ?? 0

        func sendNext() {
            if didFinish { try? handle.close(); return }
            if remaining <= 0 {
                try? handle.close()
                flushTraffic()
                finish()
                return
            }
            let chunkSize = Int(min(Int64(256 * 1024), remaining))
            guard let data = try? handle.read(upToCount: chunkSize), !data.isEmpty else {
                try? handle.close()
                flushTraffic()
                finish()
                return
            }
            remaining -= Int64(data.count)

            if isTunnel, rateKBps > 0 {
                let seconds = Double(data.count) / (Double(rateKBps) * 1024.0)
                if seconds > 0 { Thread.sleep(forTimeInterval: seconds) }
            }

            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil { try? handle.close(); self.cancel(); return }
                self.bytesOut += Int64(data.count)
                sendNext()
            })
        }

        sendNext()
    }

    private func sendRangeNotSatisfiable(size: Int64, headers: [String: String]) {
        var responseHeaders = headers
        responseHeaders["Content-Range"] = "bytes */\(size)"
        responseHeaders["Content-Length"] = "0"
        responseHeaders["Connection"] = "close"
        responseHeaders["Server"] = "PitHub/1.0"
        responseHeaders["Date"] = PitHubFormat.httpDate()
        var lines = ["HTTP/1.1 416 \(PitHubHTTPStatusText.text(for: 416))"]
        for (name, value) in responseHeaders.sorted(by: { $0.key < $1.key }) {
            lines.append("\(name): \(value)")
        }
        let data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.finish()
        })
    }

    private func sendSimpleError(status: Int) {
        guard !responseSent else { return }
        responseSent = true
        let body = Data("{\"ok\":false,\"error\":\"\(PitHubHTTPStatusText.text(for: status))\"}".utf8)
        let headers = [
            "Content-Type": "application/json; charset=utf-8",
            "Content-Length": String(body.count),
            "Connection": "close",
            "Server": "PitHub/1.0",
            "Date": PitHubFormat.httpDate()
        ]
        var lines = ["HTTP/1.1 \(status) \(PitHubHTTPStatusText.text(for: status))"]
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            lines.append("\(name): \(value)")
        }
        let head = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        connection.send(content: head + body, completion: .contentProcessed { [weak self] _ in
            self?.finish()
        })
    }

    private func finish() {
        guard !didFinish else { return }
        flushTraffic()
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.cancel()
        })
    }

    private func flushTraffic() {
        guard bytesOut > 0, let request = currentRequest else { return }
        server?.recordTraffic(isTunnel: request.isTunnel, bytesIn: 0, bytesOut: bytesOut)
        bytesOut = 0
    }

    func cancel() {
        guard !didFinish else { return }
        didFinish = true
        timeoutWorkItem?.cancel()
        try? spoolHandle?.close()
        if let spoolURL { try? FileManager.default.removeItem(at: spoolURL) }
        if let cleanupFileURL { try? FileManager.default.removeItem(at: cleanupFileURL) }
        connection.cancel()
        server?.connectionClosed(id)
    }

    // MARK: - Range

    private enum ParsedRange {
        case none
        case valid(offset: Int64, length: Int64)
        case unsatisfiable
    }

    private static func parseRange(_ header: String, size: Int64) -> ParsedRange {
        let value = header.trimmingCharacters(in: .whitespaces)
        guard value.lowercased().hasPrefix("bytes=") else { return .none }
        let spec = String(value.dropFirst(6)).split(separator: ",").first.map(String.init) ?? ""
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return .unsatisfiable }
        let startText = parts[0].trimmingCharacters(in: .whitespaces)
        let endText = parts[1].trimmingCharacters(in: .whitespaces)

        if startText.isEmpty {
            // bytes=-N 取最后 N 字节
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
}
