//
//  DashLinkPlugin.swift
//  PitHubDashLink
//
//  快捷指令网关：网页按钮 → shortcuts://run-shortcut → 本机快捷指令。
//
//  iOS 沙盒限制：
//  1. 没有公开 API 可以枚举“快捷指令”App 中已有的快捷指令，按钮需要手动填写名称。
//  2. 通过 URL Scheme 调用快捷指令后，系统不会把执行结果回传给调用方。
//     因此本插件提供 /api/dash/callback?runId=...，可在快捷指令最后加一个
//     “获取 URL 内容”动作，把结果 POST 回来，本机记录执行结果。
//  3. 回调接口只凭不可猜测的 runId 授权（与临时分享链接同一思路），文档已标注。
//

import Foundation
import UIKit
import PitHubCore

public struct DashButton: Codable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var shortcutName: String
    public var inputTemplate: String
    public var color: String
    public var icon: String
    public var cooldownSeconds: Int
    public var createdAt: Date

    public func jsonObject(cooldownRemaining: Int = 0) -> [String: Any] {
        [
            "id": id,
            "title": title,
            "shortcutName": shortcutName,
            "inputTemplate": inputTemplate,
            "color": color,
            "icon": icon,
            "cooldownSeconds": cooldownSeconds,
            "cooldownRemaining": cooldownRemaining,
            "createdAt": PitHubFormat.iso(createdAt)
        ]
    }
}

public struct DashRun: Codable, Identifiable, Equatable {
    public var id: String
    public var buttonID: String
    public var buttonTitle: String
    public var shortcutName: String
    public var input: String
    public var status: String          // launched / completed / failed
    public var message: String
    public var result: String
    public var source: String
    public var createdAt: Date
    public var finishedAt: Date?

    public func jsonObject(callbackURL: String = "") -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "buttonId": buttonID,
            "buttonTitle": buttonTitle,
            "shortcutName": shortcutName,
            "input": input,
            "status": status,
            "message": message,
            "result": result,
            "source": source,
            "createdAt": PitHubFormat.iso(createdAt),
            "callbackURL": callbackURL
        ]
        if let finishedAt { dict["finishedAt"] = PitHubFormat.iso(finishedAt) }
        return dict
    }
}

final class DashLinkStore {

    private let directory: URL
    private let buttonsURL: URL
    private let runsURL: URL
    private let lock = NSLock()
    private var buttons: [DashButton] = []
    private var runs: [DashRun] = []

    init(directory: URL) throws {
        self.directory = directory
        self.buttonsURL = directory.appendingPathComponent("buttons.json")
        self.runsURL = directory.appendingPathComponent("runs.json")
        try PitHubPaths.ensureDirectory(directory)
        load()
    }

    func allButtons() -> [DashButton] {
        lock.lock(); defer { lock.unlock() }
        return buttons.sorted { $0.createdAt < $1.createdAt }
    }

    func button(id: String) -> DashButton? {
        lock.lock(); defer { lock.unlock() }
        return buttons.first { $0.id == id }
    }

    func saveButton(_ button: DashButton) {
        lock.lock()
        if let index = buttons.firstIndex(where: { $0.id == button.id }) {
            buttons[index] = button
        } else {
            buttons.append(button)
        }
        persistButtonsLocked()
        lock.unlock()
    }

    @discardableResult
    func deleteButton(id: String) -> Bool {
        lock.lock()
        let before = buttons.count
        buttons.removeAll { $0.id == id }
        persistButtonsLocked()
        lock.unlock()
        return buttons.count != before
    }

    func lastRunDate(buttonID: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return runs.first(where: { $0.buttonID == buttonID })?.createdAt
    }

    func appendRun(_ run: DashRun, settings: PitHubSettings) {
        lock.lock()
        runs.insert(run, at: 0)
        let maxRuns = max(10, settings.dashLink.maxRuns)
        if runs.count > maxRuns { runs = Array(runs.prefix(maxRuns)) }
        persistRunsLocked()
        lock.unlock()
    }

    func updateRun(id: String, status: String, result: String, message: String) -> DashRun? {
        lock.lock()
        guard let index = runs.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return nil
        }
        runs[index].status = status
        runs[index].result = result
        runs[index].message = message
        runs[index].finishedAt = Date()
        let updated = runs[index]
        persistRunsLocked()
        lock.unlock()
        return updated
    }

    func listRuns(limit: Int) -> [DashRun] {
        lock.lock(); defer { lock.unlock() }
        return Array(runs.prefix(max(1, min(limit, 500))))
    }

    func clearRuns() {
        lock.lock()
        runs.removeAll()
        persistRunsLocked()
        lock.unlock()
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: buttonsURL),
           let decoded = try? decoder.decode([DashButton].self, from: data) {
            buttons = decoded
        }
        if let data = try? Data(contentsOf: runsURL),
           let decoded = try? decoder.decode([DashRun].self, from: data) {
            runs = decoded
        }
    }

    private func persistButtonsLocked() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(buttons) {
            try? data.write(to: buttonsURL, options: .atomic)
        }
    }

    private func persistRunsLocked() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(runs) {
            try? data.write(to: runsURL, options: .atomic)
        }
    }
}

public final class DashLinkPlugin: PitHubPlugin {

    public var id: String { "dash" }
    public var displayName: String { "DashLink" }
    public var summary: String { "快捷指令网关 · 自定义按钮 · 冷却与执行日志" }
    public var systemImage: String { "bolt.fill" }
    public var apiPrefix: String { "/api/dash" }
    public var extraPrefixes: [String] { [] }
    public var defaultEnabled: Bool { false }

    private weak var host: PitHubPluginHost?
    private var store: DashLinkStore?

    public init() {}

    public func attach(host: PitHubPluginHost, dataDirectory: URL) {
        self.host = host
        do {
            store = try DashLinkStore(directory: dataDirectory)
        } catch {
            PitHubLog.error("DashLink 初始化失败：\(error.localizedDescription)")
        }
    }

    public func handle(_ request: HTTPRequest,
                       subPath: String,
                       context: PitHubPluginRequestContext,
                       respond: @escaping (HTTPResponse) -> Void) {
        guard let store, let host else {
            respond(.error(503, "DashLink 尚未就绪"))
            return
        }

        var route = subPath
        if route.hasPrefix("/") { route.removeFirst() }
        if route.hasSuffix("/") { route.removeLast() }

        let settings = context.settings

        switch route {
        case "buttons":
            guard request.method == "GET" else { respond(.error(405, "仅支持 GET")); return }
            let buttons = store.allButtons().map { button -> [String: Any] in
                button.jsonObject(cooldownRemaining: cooldownRemaining(button: button, settings: settings, store: store))
            }
            respond(.json(["ok": true, "buttons": buttons, "cooldownSeconds": settings.dashLink.cooldownSeconds]))

        case "button/save":
            guard context.role >= .user else { respond(.error(403, "需要登录权限")); return }
            guard request.method == "POST" else { respond(.error(405, "仅支持 POST")); return }
            do {
                let dict = try requireJSON(request)
                let title = (dict["title"] as? String ?? "").trimmed
                let shortcut = (dict["shortcutName"] as? String ?? "").trimmed
                guard !title.isEmpty, !shortcut.isEmpty else {
                    respond(.error(400, "按钮名称与快捷指令名称不能为空")); return
                }
                let existingID = dict["id"] as? String
                let existing = existingID.flatMap { store.button(id: $0) }
                let button = DashButton(
                    id: existing?.id ?? Self.randomToken(length: 16),
                    title: String(title.prefix(60)),
                    shortcutName: String(shortcut.prefix(120)),
                    inputTemplate: dict["inputTemplate"] as? String ?? "",
                    color: sanitizeColor(dict["color"] as? String),
                    icon: String((dict["icon"] as? String ?? "bolt.fill").prefix(40)),
                    cooldownSeconds: max(0, min(3600, intValue(dict["cooldownSeconds"]) ?? 0)),
                    createdAt: existing?.createdAt ?? Date()
                )
                store.saveButton(button)
                respond(.json(["ok": true, "button": button.jsonObject()]))
            } catch {
                respond(.error(500, error.localizedDescription))
            }

        case "button/delete":
            guard context.role >= .user else { respond(.error(403, "需要登录权限")); return }
            var identifier = request.query["id"]
            if identifier == nil, let dict = try? requireJSON(request) {
                identifier = dict["id"] as? String
            }
            guard let resolved = identifier, !resolved.isEmpty else { respond(.error(400, "缺少 id")); return }
            let removed = store.deleteButton(id: resolved)
            respond(.json(["ok": true, "deleted": removed]))

        case "run":
            guard context.role >= .user else { respond(.error(403, "需要登录权限")); return }
            guard request.method == "POST" else { respond(.error(405, "仅支持 POST")); return }
            guard let dict = try? requireJSON(request),
                  let id = dict["id"] as? String,
                  let button = store.button(id: id) else {
                respond(.error(404, "按钮不存在")); return
            }
            let remaining = cooldownRemaining(button: button, settings: settings, store: store)
            guard remaining <= 0 else {
                respond(.error(429, "冷却中，请 \(remaining) 秒后再试")); return
            }

            let userText = dict["text"] as? String ?? ""
            let input = button.inputTemplate.isEmpty
                ? userText
                : button.inputTemplate.replacingOccurrences(of: "{{text}}", with: userText)
            guard let shortcutURL = Self.shortcutURL(name: button.shortcutName, input: input) else {
                respond(.error(400, "快捷指令名称无法生成链接")); return
            }

            let run = DashRun(
                id: Self.randomToken(length: 24),
                buttonID: button.id,
                buttonTitle: button.title,
                shortcutName: button.shortcutName,
                input: input,
                status: "launched",
                message: "已请求打开快捷指令",
                result: "",
                source: request.remoteAddress,
                createdAt: Date(),
                finishedAt: nil
            )
            store.appendRun(run, settings: settings)
            let callbackURL = callbackURL(runID: run.id, host: host)

            host.runOnMain {
                UIApplication.shared.open(shortcutURL, options: [:]) { success in
                    if !success {
                        PitHubLog.error("无法打开快捷指令：\(button.shortcutName)")
                    }
                }
            }
            if settings.notificationsEnabled {
                host.notifier.notify(title: "DashLink 已触发", body: button.title)
            }
            var response = HTTPResponse.json([
                "ok": true,
                "run": run.jsonObject(callbackURL: callbackURL),
                "callbackURL": callbackURL,
                "note": "iOS 不会把快捷指令结果直接回传；请在快捷指令末尾用“获取 URL 内容”POST 结果到 callbackURL。"
            ])
            response.logAction = "dash-run"
            respond(response)

        case "callback":
            // 仅凭 runId 授权（不可猜测）；runtime 已把该路径设为公开。
            guard request.method == "POST" else { respond(.error(405, "仅支持 POST")); return }
            let dict = (try? requireJSON(request)) ?? [:]
            let runID = (dict["runId"] as? String) ?? request.query["runId"] ?? ""
            guard !runID.isEmpty else { respond(.error(400, "缺少 runId")); return }
            let result = dict["result"] as? String ?? request.query["result"] ?? ""
            let failed = (dict["status"] as? String) == "failed"
            let updated = store.updateRun(
                id: runID,
                status: failed ? "failed" : "completed",
                result: result,
                message: failed ? "快捷指令报告执行失败" : "快捷指令已回调结果"
            )
            guard let updated else {
                respond(.error(404, "执行记录不存在")); return
            }
            respond(.json(["ok": true, "run": updated.jsonObject()]))

        case "runs":
            guard request.method == "GET" else { respond(.error(405, "仅支持 GET")); return }
            guard context.role >= .user else { respond(.error(403, "需要登录权限")); return }
            let limit = Int(request.query["limit"] ?? "30") ?? 30
            respond(.json([
                "ok": true,
                "runs": store.listRuns(limit: limit).map { $0.jsonObject() }
            ]))

        case "runs/clear":
            guard context.role >= .user else { respond(.error(403, "需要登录权限")); return }
            guard request.method == "POST" else { respond(.error(405, "仅支持 POST")); return }
            store.clearRuns()
            respond(.json(["ok": true]))

        default:
            respond(.error(404, "未实现的 DashLink 接口：\(route)"))
        }
    }

    // MARK: - 本机预览

    public func nativeButtons() -> [DashButton] {
        store?.allButtons() ?? []
    }

    @discardableResult
    public func nativeRun(buttonID: String, text: String = "") -> DashRun? {
        guard let store, let host, let button = store.button(id: buttonID) else { return nil }
        let remaining = cooldownRemaining(button: button, settings: host.settingsSnapshot, store: store)
        guard remaining <= 0 else { return nil }
        let input = button.inputTemplate.isEmpty
            ? text
            : button.inputTemplate.replacingOccurrences(of: "{{text}}", with: text)
        guard let url = Self.shortcutURL(name: button.shortcutName, input: input) else { return nil }
        let run = DashRun(
            id: Self.randomToken(length: 24),
            buttonID: button.id,
            buttonTitle: button.title,
            shortcutName: button.shortcutName,
            input: input,
            status: "launched",
            message: "已请求打开快捷指令",
            result: "",
            source: "app",
            createdAt: Date(),
            finishedAt: nil
        )
        store.appendRun(run, settings: host.settingsSnapshot)
        host.runOnMain {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
        return run
    }

    public func nativeRuns(limit: Int = 30) -> [DashRun] {
        store?.listRuns(limit: limit) ?? []
    }

    // MARK: - 工具

    private func cooldownRemaining(button: DashButton, settings: PitHubSettings, store: DashLinkStore) -> Int {
        let cooldown = button.cooldownSeconds > 0 ? button.cooldownSeconds : settings.dashLink.cooldownSeconds
        guard cooldown > 0, let last = store.lastRunDate(buttonID: button.id) else { return 0 }
        let elapsed = Int(Date().timeIntervalSince(last))
        return max(0, cooldown - elapsed)
    }

    private func callbackURL(runID: String, host: PitHubPluginHost) -> String {
        let base = (host.publicURL ?? host.lanURL).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(base)/api/dash/callback?runId=\(runID)"
    }

    private func requireJSON(_ request: HTTPRequest) throws -> [String: Any] {
        guard let data = request.bodyData(maxBytes: 4 * 1024 * 1024),
              let dict = PitHubJSON.decodeDictionary(data) else {
            throw NSError(domain: "PitHub.DashLink", code: 400,
                          userInfo: [NSLocalizedDescriptionKey: "请求体不是有效的 JSON"])
        }
        return dict
    }

    private func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private func sanitizeColor(_ raw: String?) -> String {
        guard let raw, raw.count <= 20 else { return "#5B8DEF" }
        return raw.hasPrefix("#") ? raw : "#5B8DEF"
    }

    private static func shortcutURL(name: String, input: String) -> URL? {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        var items = [URLQueryItem(name: "name", value: name)]
        if !input.isEmpty {
            items.append(URLQueryItem(name: "input", value: "text"))
            items.append(URLQueryItem(name: "text", value: input))
        }
        components.queryItems = items
        return components.url
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
