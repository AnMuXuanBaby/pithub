//
//  PitHubRuntime.swift
//  PitHubCore
//
//  全局运行时：把 HTTP 服务、鉴权、插件、隧道、缓存、日志、流量、
//  定时刷新等串在一起。网页与 SwiftUI 共用这一个实例。
//

import Foundation
import Combine
import UIKit

public final class PitHubRuntime: ObservableObject, PitHubPluginHost {

    // MARK: - 对 UI 暴露的状态

    @Published public private(set) var isRunning = false
    @Published public private(set) var port: UInt16 = 0
    @Published public private(set) var localURL: String = ""
    @Published public private(set) var tunnelStatus: PitHubTunnelStatus
    @Published public private(set) var activeConnections: Int = 0
    @Published public private(set) var traffic: PitHubTrafficSnapshot
    @Published public private(set) var lastError: String?
    @Published public private(set) var pluginDescriptors: [PitHubPluginDescriptor] = []
    @Published public private(set) var startedAt: Date?
    @Published public private(set) var currentSettings: PitHubSettings

    // MARK: - 公共组件

    public let settingsStore: PitHubSettingsStore
    public let authManager: PitHubAuthManager
    public let logStore: PitHubAccessLogStore
    public let trafficStats: PitHubTrafficStats
    public let cache: PitHubLRUCache
    public let thumbnailCache: PitHubLRUCache
    public let photoLibrary: PitHubPhotoLibrary
    public let notifier: PitHubNotifier
    public let pluginManager: PitHubPluginManager
    public let server: PitHubHTTPServer
    public let tunnel: PitHubTunnelManager
    public let webAssets: PitHubWebAssets?

    // MARK: - 内部

    var settingsCancellable: AnyCancellable?
    var refreshTimer: DispatchSourceTimer?
    var lastAppliedSettings: PitHubSettings
    var restartScheduled = false
    var loginFailures: [String: (count: Int, first: Date)] = [:]
    let loginLock = NSLock()

    // MARK: - 协议实现

    public var settingsSnapshot: PitHubSettings { settingsStore.current }

    public var lanURL: String {
        if isRunning && !localURL.isEmpty { return localURL }
        let ip = PitHubNetworkInfo.primaryIPv4() ?? "127.0.0.1"
        let value = UInt16(clamping: settingsStore.current.port)
        return PitHubNetworkInfo.urlString(host: ip, port: value == 0 ? 8080 : value)
    }

    public var publicURL: String? {
        tunnel.status.active ? tunnel.status.publicURL : nil
    }

    public var accessLog: PitHubAccessLogStore { logStore }

    /// 分享链接等使用的基地址：优先公网，其次局域网；不带末尾斜杠
    public var shareBaseURL: String {
        var base = publicURL?.isEmpty == false ? (publicURL ?? "") : lanURL
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    // MARK: - 初始化

    public init(plugins: [PitHubPlugin]) {
        do {
            try PitHubPaths.bootstrap()
        } catch {
            PitHubLog.error("目录初始化失败：\(error.localizedDescription)")
        }

        let store = PitHubSettingsStore()
        let initialSettings = store.current
        self.settingsStore = store
        self.lastAppliedSettings = initialSettings
        self.currentSettings = initialSettings
        self.authManager = PitHubAuthManager(settingsProvider: { store.current })
        self.logStore = PitHubAccessLogStore(capacity: max(500, initialSettings.logRetention))
        let stats = PitHubTrafficStats()
        self.trafficStats = stats
        self.traffic = stats.current
        self.cache = PitHubLRUCache(
            directory: PitHubPaths.cache.appendingPathComponent("shared", isDirectory: true),
            maxBytes: Int64(initialSettings.cacheLimitMB) * 1024 * 1024
        )
        self.thumbnailCache = PitHubLRUCache(
            directory: PitHubPaths.thumbnails,
            maxBytes: 300 * 1024 * 1024
        )
        self.photoLibrary = PitHubPhotoLibrary.shared
        self.notifier = PitHubNotifier.shared
        self.pluginManager = PitHubPluginManager(plugins: plugins, enabledStates: initialSettings.pluginEnabled)
        self.server = PitHubHTTPServer()
        let tunnelManager = PitHubTunnelManager(settings: initialSettings)
        self.tunnel = tunnelManager
        self.tunnelStatus = tunnelManager.status
        self.webAssets = PitHubWebAssets.locate()

        if webAssets == nil {
            PitHubLog.error("未找到内嵌 www 目录，网页将无法访问。请检查 Bundle 资源。")
        }

        server.traffic = trafficStats
        server.onConnectionsChanged = { [weak self] count in
            self?.activeConnections = count
        }
        server.handler = { [weak self] request, respond in
            guard let self else {
                respond(.error(503, "服务已释放"))
                return
            }
            self.handle(request, respond: respond)
        }

        tunnel.requestHandler = { [weak self] request, respond in
            guard let self else {
                respond(.error(503, "服务已释放"))
                return
            }
            self.handle(request, respond: respond)
        }
        tunnel.onUpdate = { [weak self] status in
            guard let self else { return }
            let wasActive = self.tunnelStatus.active
            self.tunnelStatus = status
            if wasActive && !status.active && self.isRunning, self.currentSettings.notificationsEnabled {
                self.notifier.notify(title: "PitHub 隧道断开", body: status.message)
            }
        }

        // 插件挂载：每个插件拥有独立数据目录
        for plugin in plugins {
            let dir = PitHubPaths.pluginData.appendingPathComponent(plugin.id, isDirectory: true)
            try? PitHubPaths.ensureDirectory(dir)
            plugin.attach(host: self, dataDirectory: dir)
        }

        refreshPluginDescriptors()

        settingsCancellable = store.$settings
            .dropFirst()
            .sink { [weak self] newSettings in
                self?.applySettingsChange(newSettings)
            }

        authManager.refreshTimeout()
    }

    // MARK: - 启停

    public func start() {
        guard !isRunning else { return }
        let settings = settingsStore.current
        lastAppliedSettings = settings
        lastError = nil

        server.rateLimitKBps = settings.tunnelEnabled ? max(0, settings.wanRateLimitKBps) : 0

        let desiredPort = UInt16(clamping: max(1, min(65535, settings.port)))
        server.start(
            port: desiredPort,
            serviceName: settings.bonjourName,
            onReady: { [weak self] actualPort in
                guard let self else { return }
                self.port = actualPort
                let ip = PitHubNetworkInfo.primaryIPv4() ?? "127.0.0.1"
                self.localURL = PitHubNetworkInfo.urlString(host: ip, port: actualPort)
                self.isRunning = true
                self.startedAt = Date()
                self.lastError = nil
                self.tunnel.apply(settings: self.settingsStore.current)
                self.startRefreshTimer()
                self.updateIdleTimer()
                if settings.notificationsEnabled {
                    self.notifier.notify(title: "PitHub 已启动", body: "局域网地址：\(self.localURL)")
                }
                PitHubLog.info("PitHub 启动完成：\(self.localURL)")
            },
            onFailure: { [weak self] message in
                guard let self else { return }
                self.isRunning = false
                self.lastError = message
                self.localURL = ""
                self.stopRefreshTimer()
                self.tunnel.stop()
                self.tunnelStatus = self.tunnel.status
                if settings.notificationsEnabled {
                    self.notifier.notify(title: "PitHub 启动失败", body: message)
                }
            }
        )
    }

    public func stop() {
        isRunning = false
        server.stop()
        tunnel.stop()
        tunnelStatus = tunnel.status
        localURL = ""
        port = 0
        startedAt = nil
        stopRefreshTimer()
        trafficStats.persist()
        updateIdleTimer()
        PitHubLog.info("PitHub 已停止")
    }

    public func toggle() {
        if isRunning { stop() } else { start() }
    }

    private func startRefreshTimer() {
        stopRefreshTimer()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.traffic = self.trafficStats.current
        }
        timer.resume()
        refreshTimer = timer
    }

    private func stopRefreshTimer() {
        refreshTimer?.cancel()
        refreshTimer = nil
    }

    private func updateIdleTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let settings = self.settingsStore.current
            UIApplication.shared.isIdleTimerDisabled = self.isRunning && settings.preventAutoLock
        }
    }

    // MARK: - 设置联动

    func applySettingsChange(_ newSettings: PitHubSettings) {
        let previous = lastAppliedSettings
        lastAppliedSettings = newSettings
        currentSettings = newSettings

        authManager.refreshTimeout()
        cache.setMaxBytes(Int64(max(64, newSettings.cacheLimitMB)) * 1024 * 1024)
        server.rateLimitKBps = newSettings.tunnelEnabled ? max(0, newSettings.wanRateLimitKBps) : 0
        pluginManager.apply(enabledStates: newSettings.pluginEnabled)
        refreshPluginDescriptors()
        updateIdleTimer()

        if isRunning {
            if newSettings.tunnelEnabled {
                tunnel.apply(settings: newSettings)
            } else if previous.tunnelEnabled {
                tunnel.stop()
            }
        }

        if isRunning,
           UInt16(clamping: max(1, min(65535, newSettings.port))) != port || newSettings.bonjourName != previous.bonjourName {
            scheduleRestart()
        }

        trafficStats.persist()
    }

    private func scheduleRestart() {
        guard !restartScheduled else { return }
        restartScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.restartScheduled = false
            guard self.isRunning else { return }
            let wasRunning = self.isRunning
            self.server.stop()
            self.isRunning = false
            self.localURL = ""
            if wasRunning { self.start() }
        }
    }

    public func refreshPluginDescriptors() {
        let descriptors = pluginManager.descriptors(settings: settingsStore.current)
        if Thread.isMainThread {
            pluginDescriptors = descriptors
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.pluginDescriptors = descriptors
            }
        }
    }

    public func setPluginEnabled(id: String, enabled: Bool) {
        settingsStore.update { settings in
            settings.pluginEnabled[id] = enabled
        }
        refreshPluginDescriptors()
    }

    public func updateSettings(_ mutate: (inout PitHubSettings) -> Void) {
        settingsStore.update(mutate)
        refreshPluginDescriptors()
    }

    public func runOnMain(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    // MARK: - 路由入口

    func handle(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        // Relay 是直连 Runtime 的；服务开关关闭时也必须拒绝，避免绕过 App 的停服。
        // 本地连接允许在 isRunning 主线程回调完成前的极短窗口内通过。
        guard isRunning || request.isLocalConnection else {
            respond(.error(503, "服务未启动"))
            return
        }
        let requestID = UUID().uuidString
        let role = resolveRole(request)

        let finalRespond: (HTTPResponse) -> Void = { [weak self] response in
            guard let self else {
                respond(response)
                return
            }
            var final = response
            self.addCORSHeaders(request, to: &final)
            self.recordAccess(request, response: final, role: role, requestID: requestID)
            if !request.isLocalConnection {
                self.recordRelayTraffic(request, response: final)
            }
            respond(final)
        }

        // CORS 预检
        if request.method == "OPTIONS", request.path.hasPrefix("/api/") {
            var response = HTTPResponse(status: 204)
            response.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, HEAD, OPTIONS"
            response.headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization, Range, X-Requested-With"
            response.headers["Access-Control-Max-Age"] = "86400"
            finalRespond(response)
            return
        }

        // 健康检查（公网检测用，不需要鉴权）
        if request.path == "/api/health" {
            finalRespond(.json(["ok": true, "name": "PitHub", "time": PitHubFormat.iso()]))
            return
        }

        // 临时分享链接：token 已经限定到单个文件，单独处理
        if request.path.hasPrefix("/s/") || request.path == "/s" {
            if let match = pluginManager.match(path: request.path) {
                dispatchPlugin(match, request: request, role: .guest, requestID: requestID, respond: finalRespond)
            } else {
                finalRespond(.error(404, "分享链接无效"))
            }
            return
        }

        // 未登录：只允许访问静态页面 / 登录相关接口
        if role == nil {
            // 快捷指令回调：runId 本身是不可猜测的临时能力令牌
            if request.path == "/api/dash/callback" {
                if let match = pluginManager.match(path: request.path) {
                    dispatchPlugin(match, request: request, role: .guest, requestID: requestID, respond: finalRespond)
                } else {
                    finalRespond(.error(404, "DashLink 未启用"))
                }
                return
            }
            switch request.path {
            case "/api/auth/login", "/api/auth/status":
                finalRespond(authRoute(request))
                return
            default:
                if request.path.hasPrefix("/api/") {
                    finalRespond(.error(401, "请先登录"))
                } else if request.path == "/webdav" || request.path.hasPrefix("/webdav/") {
                    var response = HTTPResponse.error(401, "WebDAV 需要认证")
                    response.headers["WWW-Authenticate"] = "Basic realm=\"PitHub\", charset=\"UTF-8\""
                    finalRespond(response)
                } else {
                    finalRespond(staticResponse(for: request.path))
                }
                return
            }
        }

        guard let authenticatedRole = role else {
            finalRespond(.error(401, "请先登录"))
            return
        }

        // 内置 API
        if request.path.hasPrefix("/api/") {
            if let builtin = handleBuiltinAPI(request, role: authenticatedRole) {
                finalRespond(builtin)
                return
            }
        }

        // WebDAV / 插件路由
        if let match = pluginManager.match(path: request.path) {
            dispatchPlugin(match, request: request, role: authenticatedRole, requestID: requestID, respond: finalRespond)
            return
        }

        // 静态页面（SPA 路由回退到 index.html）
        finalRespond(staticResponse(for: request.path))
    }

    private func dispatchPlugin(_ match: (plugin: PitHubPlugin, subPath: String),
                                request: HTTPRequest,
                                role: PitHubRole,
                                requestID: String,
                                respond: @escaping (HTTPResponse) -> Void) {
        guard pluginManager.isEnabled(match.plugin.id) else {
            respond(.error(404, "插件 \(match.plugin.displayName) 已禁用"))
            return
        }
        let context = PitHubPluginRequestContext(
            role: role,
            settings: settingsStore.current,
            remoteAddress: request.remoteAddress,
            isTunnel: request.isTunnel,
            requestID: requestID,
            sessionToken: sessionToken(request)
        )
        match.plugin.handle(request, subPath: match.subPath, context: context, respond: respond)
    }

    // MARK: - 鉴权上下文

    func resolveRole(_ request: HTTPRequest) -> PitHubRole? {
        let cookieToken = request.cookies[PitHubAuthManager.cookieName]
        let authorization = request.header("authorization")
        var bearer: String?
        var basic: String?
        if let authorization {
            if authorization.lowercased().hasPrefix("bearer ") {
                bearer = String(authorization.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            } else if authorization.lowercased().hasPrefix("basic ") {
                basic = authorization
            }
        }
        return authManager.authenticate(
            cookieToken: cookieToken,
            bearer: bearer,
            basic: basic,
            settings: settingsStore.current
        )
    }

    func sessionToken(_ request: HTTPRequest) -> String? {
        if let cookie = request.cookies[PitHubAuthManager.cookieName] { return cookie }
        if let auth = request.header("authorization"), auth.lowercased().hasPrefix("bearer ") {
            return String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // MARK: - 静态资源

    func staticResponse(for path: String) -> HTTPResponse {
        if path == "/" || path.isEmpty {
            return webAssets?.indexResponse() ?? .error(404, "未找到内嵌网页，请检查 www 资源")
        }
        if path == "/favicon.ico" || path == "/favicon.png" {
            return webAssets?.response(for: "assets/favicon.png") ?? .error(404, "not found")
        }
        if path == "/manifest.webmanifest" || path == "/manifest.json" {
            return webAssets?.response(for: "manifest.webmanifest") ?? .error(404, "not found")
        }
        if let response = webAssets?.response(for: String(path.dropFirst())) {
            return response
        }
        // SPA 路由：/login /file /photo /clip /dash /settings /logs 等
        let spaPrefixes = ["/login", "/file", "/photo", "/clip", "/dash", "/settings", "/logs", "/dashboard"]
        if spaPrefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return webAssets?.indexResponse() ?? .error(404, "未找到内嵌网页")
        }
        return .error(404, "Not Found")
    }

    // MARK: - 日志 / 流量

    func recordAccess(_ request: HTTPRequest, response: HTTPResponse, role: PitHubRole?, requestID: String) {
        let path = request.path
        if path.hasPrefix("/assets/") || path == "/favicon.ico" || path == "/manifest.webmanifest" {
            return
        }
        let action = response.logAction ?? defaultAction(for: request)
        let entry = PitHubAccessLogEntry(
            ip: request.remoteAddress,
            method: request.method,
            path: path,
            action: action,
            role: role?.rawValue ?? "share",
            status: response.status,
            bytesIn: request.bodySize,
            bytesOut: responseByteCount(response),
            tunnel: request.isTunnel
        )
        logStore.append(entry)
    }

    func defaultAction(for request: HTTPRequest) -> String {
        if request.path.hasPrefix("/webdav") { return "webdav-\(request.method.lowercased())" }
        if request.path.hasPrefix("/s/") { return "share-download" }
        if request.path.hasPrefix("/api/file") {
            if request.path.contains("upload") { return "upload" }
            if request.path.contains("download") { return "download" }
            if request.path.contains("mkdir") { return "mkdir" }
            if request.path.contains("delete") { return "delete" }
            if request.path.contains("rename") { return "rename" }
            if request.path.contains("move") { return "move" }
            if request.path.contains("share") { return "share" }
            if request.path.contains("zip") { return "zip" }
            return "file"
        }
        if request.path.hasPrefix("/api/photo") { return "photo" }
        if request.path.hasPrefix("/api/clip") { return "clip" }
        if request.path.hasPrefix("/api/dash") { return "dash" }
        if request.path.hasPrefix("/api/auth") { return "auth" }
        if request.path.hasPrefix("/api/settings") { return "settings" }
        if request.path.hasPrefix("/api/logs") { return "logs" }
        if request.path.hasPrefix("/api/plugin") { return "plugin" }
        return request.method.lowercased()
    }

    func responseByteCount(_ response: HTTPResponse) -> Int64 {
        switch response.body {
        case .empty:
            return 0
        case .data(let data):
            return Int64(data.count)
        case .file(let url):
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
    }

    func recordRelayTraffic(_ request: HTTPRequest, response: HTTPResponse) {
        // 只有 Relay 通道的请求需要在这里计数；
        // 直接打到 NWListener 的隧道请求已经由 HTTP 连接层统计。
        guard request.header("x-pithub-transport")?.lowercased() == "relay" else { return }
        trafficStats.record(
            isTunnel: true,
            bytesIn: request.bodySize,
            bytesOut: responseByteCount(response)
        )
    }

    func addCORSHeaders(_ request: HTTPRequest, to response: inout HTTPResponse) {
        guard request.path.hasPrefix("/api/") else { return }
        guard let origin = request.header("origin"), !origin.isEmpty else { return }
        response.headers["Access-Control-Allow-Origin"] = origin
        response.headers["Vary"] = "Origin"
        response.headers["Access-Control-Allow-Credentials"] = "true"
        response.headers["Access-Control-Expose-Headers"] = "Content-Length, Content-Range, Content-Disposition"
    }

    // MARK: - 状态 JSON

    func statusJSON(role: PitHubRole) -> [String: Any] {
        let settings = settingsStore.current
        let traffic = trafficStats.jsonObject()
        let plugins = pluginDescriptors.map { descriptor -> [String: Any] in
            [
                "id": descriptor.id,
                "name": descriptor.name,
                "summary": descriptor.summary,
                "icon": descriptor.systemImage,
                "prefix": descriptor.prefix,
                "enabled": descriptor.enabled,
                "defaultEnabled": descriptor.defaultEnabled
            ]
        }
        let uptime: Int
        if let startedAt {
            uptime = Int(Date().timeIntervalSince(startedAt))
        } else {
            uptime = 0
        }
        return [
            "online": isRunning,
            "version": "1.0.0",
            "serverName": settings.bonjourName,
            "port": port,
            "localURL": localURL,
            "lanHost": PitHubNetworkInfo.primaryIPv4() ?? "",
            "bonjour": "_pithub._tcp",
            "tunnel": tunnel.jsonObject(),
            "shareBaseURL": shareBaseURL,
            "connections": activeConnections,
            "traffic": traffic,
            "trafficText": [
                "lan": PitHubFormat.humanBytes(trafficStats.current.lanBytesIn + trafficStats.current.lanBytesOut),
                "tunnel": PitHubFormat.humanBytes(trafficStats.current.tunnelBytesIn + trafficStats.current.tunnelBytesOut),
                "total": PitHubFormat.humanBytes(trafficStats.current.totalBytes)
            ],
            "plugins": plugins,
            "role": role.rawValue,
            "backgroundPolicy": settings.backgroundPolicy.rawValue,
            "preventAutoLock": settings.preventAutoLock,
            "guestEnabled": settings.guestEnabled,
            "defaultPassword": settings.isDefaultPassword,
            "startedAt": startedAt.map { PitHubFormat.iso($0) } ?? "",
            "uptime": uptime,
            "cacheBytes": cache.totalBytes + thumbnailCache.totalBytes
        ]
    }
}
