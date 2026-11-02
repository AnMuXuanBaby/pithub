//
//  PitHubHTTPServer.swift
//  PitHubCore
//
//  基于 Network.framework（NWListener）的原生 HTTP/1.1 服务。
//  同时通过 Bonjour（_pithub._tcp）广播服务，局域网设备可自动发现。
//

import Foundation
import Network

public final class PitHubHTTPServer {

    public private(set) var isRunning = false
    public private(set) var port: UInt16 = 0
    public var rateLimitKBps: Int = 0

    /// 请求处理入口（由 PitHubRuntime 注入）
    public var handler: ((HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void)?
    public var traffic: PitHubTrafficStats?
    public var onConnectionsChanged: ((Int) -> Void)?

    private let queue = DispatchQueue(label: "com.pithub.http.listener", qos: .userInitiated)
    private let stateQueue = DispatchQueue(label: "com.pithub.http.state")
    private var listener: NWListener?
    private var connections: [UUID: PitHubHTTPConnection] = [:]
    private var lastFailure: String?

    public init() {}

    public var activeConnections: Int {
        stateQueue.sync { connections.count }
    }

    // MARK: - 启停

    public func start(port: UInt16,
                      serviceName: String = "PitHub",
                      onReady: @escaping (UInt16) -> Void,
                      onFailure: @escaping (String) -> Void) {
        stop()

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false

        let nwPort: NWEndpoint.Port
        if port == 0 {
            nwPort = .any
        } else if let value = NWEndpoint.Port(rawValue: port) {
            nwPort = value
        } else {
            onFailure("端口无效：\(port)")
            return
        }

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            onFailure("监听失败：\(error.localizedDescription)")
            return
        }

        let name = serviceName.isEmpty ? "PitHub" : serviceName
        listener.service = NWListener.Service(name: name, type: "_pithub._tcp")
        self.listener = listener

        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            switch state {
            case .ready:
                let actualPort = listener.port?.rawValue ?? port
                self.stateQueue.sync {
                    self.isRunning = true
                    self.port = actualPort
                    self.lastFailure = nil
                }
                PitHubLog.info("HTTP 服务已启动，端口 \(actualPort)，Bonjour: \(name)")
                DispatchQueue.main.async { onReady(actualPort) }
            case .failed(let error):
                let message = error.localizedDescription
                self.stateQueue.sync {
                    self.isRunning = false
                    self.lastFailure = message
                }
                PitHubLog.error("HTTP 监听失败：\(message)")
                DispatchQueue.main.async { onFailure(message) }
                self.stop()
            case .cancelled:
                self.stateQueue.sync { self.isRunning = false }
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        listener.start(queue: queue)
    }

    public func stop() {
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil

        let current: [PitHubHTTPConnection]
        stateQueue.sync {
            current = Array(connections.values)
            connections.removeAll()
            isRunning = false
        }
        for connection in current {
            connection.cancel()
        }
        DispatchQueue.main.async { [weak self] in
            self?.onConnectionsChanged?(0)
        }
    }

    public var failureMessage: String? {
        stateQueue.sync { lastFailure }
    }

    // MARK: - 连接

    private func accept(_ connection: NWConnection) {
        // 每个连接独立队列，避免一个大文件下载阻塞其它请求
        let connectionQueue = DispatchQueue(label: "com.pithub.http.connection", qos: .userInitiated)
        let handler = PitHubHTTPConnection(connection: connection, queue: connectionQueue, server: self)
        handler.onRequest = { [weak self] request, httpConnection in
            guard let self, let handler = self.handler else {
                httpConnection.send(.error(503, "服务尚未就绪"))
                return
            }
            handler(request, { response in
                httpConnection.send(response)
            })
        }

        stateQueue.sync {
            connections[handler.id] = handler
        }
        let count = activeConnections
        DispatchQueue.main.async { [weak self] in
            self?.onConnectionsChanged?(count)
        }

        connection.start(queue: connectionQueue)
        handler.start()
    }

    func connectionClosed(_ id: UUID) {
        stateQueue.sync {
            connections.removeValue(forKey: id)
        }
        let count = activeConnections
        DispatchQueue.main.async { [weak self] in
            self?.onConnectionsChanged?(count)
        }
    }

    func recordTraffic(isTunnel: Bool, bytesIn: Int64, bytesOut: Int64) {
        traffic?.record(isTunnel: isTunnel, bytesIn: bytesIn, bytesOut: bytesOut)
    }
}
