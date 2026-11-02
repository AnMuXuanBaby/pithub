//
//  PitHubRuntimeAPI.swift
//  PitHubCore
//
//  内置 API：状态、登录、插件开关、设置、日志、缓存、二维码、隧道指引。
//  插件自己的 API 由各插件模块处理（/api/file、/api/photo、/api/clip、/api/dash）。
//

import Foundation

extension PitHubRuntime {

    // MARK: - 内置 API 分发

    func handleBuiltinAPI(_ request: HTTPRequest, role: PitHubRole) -> HTTPResponse? {
        let path = request.path

        if path == "/api/auth/login" || path == "/api/auth/status" || path == "/api/auth/logout" {
            return authRoute(request)
        }

        if path == "/api/status" {
            guard request.method == "GET" else { return HTTPResponse.error(405, "仅支持 GET") }
            return HTTPResponse.json(statusJSON(role: role))
        }

        if path == "/api/plugin/list" {
            guard request.method == "GET" else { return HTTPResponse.error(405, "仅支持 GET") }
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
            return HTTPResponse.json(["ok": true, "plugins": plugins])
        }

        if path == "/api/plugin/enable" || path == "/api/plugin/disable" {
            guard role == .admin else { return HTTPResponse.error(403, "需要管理员权限") }
            guard request.method == "POST" else { return HTTPResponse.error(405, "仅支持 POST") }
            guard let data = request.bodyData(maxBytes: 1024 * 1024),
                  let dict = PitHubJSON.decodeDictionary(data),
                  let id = dict["id"] as? String,
                  pluginManager.plugin(id: id) != nil else {
                return HTTPResponse.error(400, "缺少有效的插件 id")
            }
            let enabled = path == "/api/plugin/enable"
            setPluginEnabled(id: id, enabled: enabled)
            var response = HTTPResponse.json(["ok": true, "id": id, "enabled": enabled])
            response.logAction = enabled ? "plugin-enable" : "plugin-disable"
            return response
        }

        if path == "/api/settings" {
            if request.method == "GET" {
                return HTTPResponse.json(["ok": true, "settings": settingsStore.current.publicJSON()])
            }
            guard role == .admin else { return HTTPResponse.error(403, "需要管理员权限") }
            guard request.method == "POST" || request.method == "PUT" else {
                return HTTPResponse.error(405, "仅支持 GET / POST")
            }
            guard let data = request.bodyData(maxBytes: 2 * 1024 * 1024),
                  let dict = PitHubJSON.decodeDictionary(data) else {
                return HTTPResponse.error(400, "设置格式无效")
            }
            if let error = applySettingsPayload(dict) {
                return HTTPResponse.error(400, error)
            }
            var response = HTTPResponse.json(["ok": true, "settings": settingsStore.current.publicJSON()])
            response.logAction = "settings-update"
            return response
        }

        if path == "/api/logs" {
            guard role >= .user else { return HTTPResponse.error(403, "需要登录权限") }
            guard request.method == "GET" else { return HTTPResponse.error(405, "仅支持 GET") }
            let offset = Int(request.query["offset"] ?? "0") ?? 0
            let limit = Int(request.query["limit"] ?? "50") ?? 50
            let query = request.query["q"] ?? ""
            let method = request.query["method"] ?? ""
            var tunnelOnly: Bool?
            if let raw = request.query["tunnel"], !raw.isEmpty {
                tunnelOnly = (raw == "1" || raw.lowercased() == "true")
            }
            let page = logStore.page(offset: offset, limit: limit, query: query, method: method, tunnelOnly: tunnelOnly)
            var response = HTTPResponse.json([
                "ok": true,
                "total": page.total,
                "offset": offset,
                "limit": limit,
                "items": page.items.map { $0.jsonObject() }
            ])
            response.logAction = "logs"
            return response
        }

        if path == "/api/logs/export" {
            guard role == .admin else { return HTTPResponse.error(403, "导出日志需要管理员权限") }
            let format = (request.query["format"] ?? "json").lowercased()
            let isText = format == "txt" || format == "text"
            let data = isText ? logStore.exportText() : logStore.exportJSON()
            let stamp = PitHubFormat.isoFromSeconds(Date().timeIntervalSince1970)
                .replacingOccurrences(of: ":", with: "-")
            let filename = "pithub-logs-\(stamp).\(isText ? "txt" : "json")"
            var response = HTTPResponse(status: 200, body: .data(data), logAction: "logs-export")
            response.headers["Content-Type"] = isText ? "text/plain; charset=utf-8" : "application/json; charset=utf-8"
            response.headers["Content-Disposition"] = "attachment; filename=\"\(filename)\""
            return response
        }

        if path == "/api/logs/clear" {
            guard role == .admin else { return HTTPResponse.error(403, "需要管理员权限") }
            guard request.method == "POST" || request.method == "DELETE" else {
                return HTTPResponse.error(405, "仅支持 POST / DELETE")
            }
            logStore.clear()
            var response = HTTPResponse.json(["ok": true])
            response.logAction = "logs-clear"
            return response
        }

        if path == "/api/cache/stats" {
            guard request.method == "GET" else { return HTTPResponse.error(405, "仅支持 GET") }
            return HTTPResponse.json([
                "ok": true,
                "sharedBytes": cache.totalBytes,
                "thumbnailBytes": thumbnailCache.totalBytes,
                "limitBytes": cache.maxBytes
            ])
        }

        if path == "/api/cache/clear" {
            guard role == .admin else { return HTTPResponse.error(403, "需要管理员权限") }
            guard request.method == "POST" else { return HTTPResponse.error(405, "仅支持 POST") }
            cache.clear()
            thumbnailCache.clear()
            let zipDir = PitHubPaths.zipCache
            if let items = try? FileManager.default.contentsOfDirectory(at: zipDir, includingPropertiesForKeys: nil) {
                for item in items { try? FileManager.default.removeItem(at: item) }
            }
            var response = HTTPResponse.json(["ok": true, "message": "缓存已清空"])
            response.logAction = "cache-clear"
            return response
        }

        if path == "/api/qr" {
            guard request.method == "GET" else { return HTTPResponse.error(405, "仅支持 GET") }
            let content = request.query["url"]?.trimmed ?? shareBaseURL
            guard let png = PitHubQRCode.pngData(for: content, pixelSize: 600) else {
                return HTTPResponse.error(500, "二维码生成失败")
            }
            var response = HTTPResponse(status: 200, body: .data(png), logAction: "qr")
            response.headers["Content-Type"] = "image/png"
            response.headers["Cache-Control"] = "no-store"
            return response
        }

        if path == "/api/tunnel/guide" {
            guard request.method == "GET" else { return HTTPResponse.error(405, "仅支持 GET") }
            let settings = settingsStore.current
            let ip = PitHubNetworkInfo.primaryIPv4() ?? "<iPhone 的局域网 IP>"
            let port = port == 0 ? UInt16(clamping: settings.port) : port
            let command = PitHubTunnelManager.cloudflareCommand(port: port)
            let frp = PitHubTunnelManager.frpConfig(
                serverAddress: "frp.example.com",
                serverPort: 7000,
                token: "替换成你的 token",
                iphoneIP: ip,
                localPort: port
            )
            return HTTPResponse.json([
                "ok": true,
                "lanIP": ip,
                "port": port,
                "cloudflareCommand": command,
                "frpConfig": frp,
                "relayGuide": [
                    "1. 在一台有公网 IP 的 VPS 上安装 Node.js 20+",
                    "2. 上传仓库 relay/ 目录并执行 npm install && npm start",
                    "3. 设置环境变量 RELAY_TOKEN 与 PUBLIC_BASE_URL（例如 https://relay.example.com）",
                    "4. 在 PitHub 设置里填 Relay 地址 https://relay.example.com 和相同 token",
                    "5. 保存后 App 会自动连出去并显示分配到的公网地址"
                ],
                "iosLimit": "iOS 沙盒不允许 App 启动 cloudflared/frpc 等外部二进制，因此这两种方案需要外部连接器；Relay 模式是 App 内一键启动。"
            ])
        }

        return nil
    }

    // MARK: - 登录相关

    func authRoute(_ request: HTTPRequest) -> HTTPResponse {
        switch (request.method, request.path) {
        case ("POST", "/api/auth/login"):
            return handleLogin(request)
        case ("GET", "/api/auth/status"):
            return handleAuthStatus(request)
        case ("POST", "/api/auth/logout"):
            return handleLogout(request)
        default:
            return HTTPResponse.error(404, "Not Found")
        }
    }

    private func handleAuthStatus(_ request: HTTPRequest) -> HTTPResponse {
        let role = resolveRole(request)
        let settings = settingsStore.current
        return HTTPResponse.json([
            "ok": true,
            "authenticated": role != nil,
            "role": role?.rawValue ?? "",
            "guestEnabled": settings.guestEnabled,
            "defaultPassword": settings.isDefaultPassword,
            "serverName": settings.bonjourName,
            "version": "1.0.0",
            "tunnelActive": tunnelStatus.active,
            "publicURL": tunnelStatus.publicURL ?? ""
        ])
    }

    private func handleLogin(_ request: HTTPRequest) -> HTTPResponse {
        let ip = request.remoteAddress
        guard canAttemptLogin(ip: ip) else {
            return HTTPResponse.error(429, "尝试次数过多，请稍后再试")
        }
        guard let data = request.bodyData(maxBytes: 1024 * 1024),
              let dict = PitHubJSON.decodeDictionary(data),
              let roleRaw = dict["role"] as? String,
              let role = PitHubRole(rawValue: roleRaw) else {
            return HTTPResponse.error(400, "登录参数无效")
        }
        let password = dict["password"] as? String ?? ""
        let remember = boolValue(dict["remember"]) ?? false

        guard let session = authManager.login(role: role, password: password, remember: remember) else {
            recordLoginFailure(ip: ip)
            return HTTPResponse.error(401, role == .guest ? "访客登录已关闭" : "密码错误")
        }
        resetLoginFailures(ip: ip)

        var headers: [String: String] = [:]
        var cookie = "\(PitHubAuthManager.cookieName)=\(session.token); Path=/; HttpOnly; SameSite=Lax"
        if remember {
            cookie += "; Max-Age=\(Int(authManager.sessionTimeoutSeconds))"
        }
        headers["Set-Cookie"] = cookie
        headers["Content-Type"] = "application/json; charset=utf-8"

        let body: [String: Any] = [
            "ok": true,
            "role": session.role.rawValue,
            "token": session.token,
            "expiresAt": PitHubFormat.iso(session.expiresAt),
            "timeoutSeconds": Int(authManager.sessionTimeoutSeconds)
        ]
        var response = HTTPResponse(status: 200, headers: headers, body: .data(PitHubJSON.data(body)))
        response.logAction = "login"
        return response
    }

    private func handleLogout(_ request: HTTPRequest) -> HTTPResponse {
        if let token = sessionToken(request) {
            authManager.logout(token: token)
        }
        var response = HTTPResponse.json(["ok": true])
        response.headers["Set-Cookie"] = PitHubCookie.deleteCookie(name: PitHubAuthManager.cookieName)
        response.logAction = "logout"
        return response
    }

    private func canAttemptLogin(ip: String) -> Bool {
        loginLock.lock(); defer { loginLock.unlock() }
        let now = Date()
        var record = loginFailures[ip]
        if let existing = record, now.timeIntervalSince(existing.first) > 600 {
            record = nil
        }
        return (record?.count ?? 0) < 6
    }

    private func recordLoginFailure(ip: String) {
        loginLock.lock(); defer { loginLock.unlock() }
        let now = Date()
        if var record = loginFailures[ip], now.timeIntervalSince(record.first) <= 600 {
            record.count += 1
            loginFailures[ip] = record
        } else {
            loginFailures[ip] = (1, now)
        }
    }

    private func resetLoginFailures(ip: String) {
        loginLock.lock(); defer { loginLock.unlock() }
        loginFailures.removeValue(forKey: ip)
    }

    // MARK: - 设置更新

    func applySettingsPayload(_ dict: [String: Any]) -> String? {
        var errorMessage: String?

        settingsStore.update { settings in
            if let value = intValue(dict["port"]), (1...65535).contains(value) {
                settings.port = value
            }
            if let value = dict["bonjourName"] as? String, !value.trimmed.isEmpty {
                settings.bonjourName = String(value.trimmed.prefix(40))
            }
            if let value = boolValue(dict["guestEnabled"]) { settings.guestEnabled = value }
            if let value = intValue(dict["sessionTimeoutMinutes"]) {
                settings.sessionTimeoutMinutes = max(5, min(60 * 24 * 30, value))
            }
            if let value = boolValue(dict["tunnelEnabled"]) { settings.tunnelEnabled = value }
            if let raw = dict["tunnelProvider"] as? String, let provider = PitHubTunnelProvider(rawValue: raw) {
                settings.tunnelProvider = provider
            }
            if let value = dict["tunnelPublicURL"] as? String {
                settings.tunnelPublicURL = value.trimmed
            }
            if let value = dict["relayURL"] as? String {
                settings.relayURL = value.trimmed
            }
            if let value = dict["relayToken"] as? String {
                settings.relayToken = value.trimmed
            }
            if let value = intValue(dict["wanRateLimitKBps"]) {
                settings.wanRateLimitKBps = max(0, min(1024 * 1024, value))
            }
            if let raw = dict["backgroundPolicy"] as? String,
               let policy = PitHubBackgroundPolicy(rawValue: raw) {
                settings.backgroundPolicy = policy
            }
            if let value = boolValue(dict["preventAutoLock"]) { settings.preventAutoLock = value }
            if let value = intValue(dict["cacheLimitMB"]) {
                settings.cacheLimitMB = max(64, min(4096, value))
            }
            if let value = intValue(dict["logRetention"]) {
                settings.logRetention = max(100, min(20000, value))
            }
            if let value = boolValue(dict["notificationsEnabled"]) { settings.notificationsEnabled = value }
            if let value = boolValue(dict["biometricForSensitive"]) { settings.biometricForSensitive = value }

            if let pluginStates = dict["pluginEnabled"] as? [String: Any] {
                for (key, rawValue) in pluginStates {
                    if let value = boolValue(rawValue) {
                        settings.pluginEnabled[key] = value
                    }
                }
            }

            if let file = dict["filePit"] as? [String: Any] {
                if let value = intValue(file["maxUploadMB"]) {
                    settings.filePit.maxUploadMB = max(1, min(1024 * 64, value))
                }
                if let raw = file["blockedExtensions"] {
                    let list = stringList(raw).map {
                        $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                    }.filter { !$0.isEmpty }
                    settings.filePit.blockedExtensions = list
                }
                if let value = intValue(file["shareExpiryMinutes"]) {
                    settings.filePit.shareExpiryMinutes = max(1, min(10080, value))
                }
                if let value = boolValue(file["allowZipDownload"]) { settings.filePit.allowZipDownload = value }
                if let value = boolValue(file["allowPhotoMount"]) { settings.filePit.allowPhotoMount = value }
                if let value = intValue(file["chunkMB"]) {
                    settings.filePit.chunkMB = max(1, min(64, value))
                }
            }

            if let photo = dict["photoNode"] as? [String: Any] {
                if let raw = photo["allowedAlbumIDs"] {
                    settings.photoNode.allowedAlbumIDs = stringList(raw).filter { !$0.isEmpty }
                }
                if let value = boolValue(photo["includeHiddenAssets"]) { settings.photoNode.includeHiddenAssets = value }
                if let value = boolValue(photo["includeVideos"]) { settings.photoNode.includeVideos = value }
                if let value = intValue(photo["thumbnailQuality"]) {
                    settings.photoNode.thumbnailQuality = max(30, min(100, value))
                }
            }

            if let clip = dict["clipHub"] as? [String: Any] {
                if let value = intValue(clip["maxRecords"]) { settings.clipHub.maxRecords = max(10, min(5000, value)) }
                if let value = intValue(clip["maxItemMB"]) { settings.clipHub.maxItemMB = max(1, min(64, value)) }
                if let value = intValue(clip["retentionDays"]) { settings.clipHub.retentionDays = max(1, min(3650, value)) }
            }

            if let dash = dict["dashLink"] as? [String: Any] {
                if let value = intValue(dash["cooldownSeconds"]) { settings.dashLink.cooldownSeconds = max(0, min(3600, value)) }
                if let value = intValue(dash["maxRuns"]) { settings.dashLink.maxRuns = max(10, min(5000, value)) }
            }

            if let password = dict["newAccessPassword"] as? String, !password.isEmpty {
                if password.count < 4 {
                    errorMessage = "访问密码至少需要 4 位"
                    return
                }
                let salt = PitHubPassword.makeSalt()
                settings.accessPasswordSalt = salt
                settings.accessPasswordHash = PitHubPassword.hash(password, salt: salt)
                settings.isDefaultPassword = false
            }

            if let password = dict["newAdminPassword"] as? String, !password.isEmpty {
                if password.count < 4 {
                    errorMessage = "管理员密码至少需要 4 位"
                    return
                }
                let salt = PitHubPassword.makeSalt()
                settings.adminPasswordSalt = salt
                settings.adminPasswordHash = PitHubPassword.hash(password, salt: salt)
            }

            if let value = boolValue(dict["resetPasswords"]), value {
                let salt = PitHubPassword.makeSalt()
                settings.accessPasswordSalt = salt
                settings.accessPasswordHash = PitHubPassword.hash("pithub", salt: salt)
                settings.adminPasswordSalt = salt
                settings.adminPasswordHash = settings.accessPasswordHash
                settings.isDefaultPassword = true
            }
        }

        if let errorMessage { return errorMessage }
        refreshPluginDescriptors()
        return nil
    }

    // MARK: - 值解析

    func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value.trimmed) }
        return nil
    }

    func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            switch value.lowercased() {
            case "true", "1", "on", "yes": return true
            case "false", "0", "off", "no": return false
            default: return nil
            }
        }
        return nil
    }

    func stringList(_ value: Any?) -> [String] {
        if let array = value as? [String] {
            return array.map { $0.trimmed }.filter { !$0.isEmpty }
        }
        if let array = value as? [Any] {
            return array.compactMap { ($0 as? String)?.trimmed }.filter { !$0.isEmpty }
        }
        if let string = value as? String {
            return string.split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty }
        }
        return []
    }
}
