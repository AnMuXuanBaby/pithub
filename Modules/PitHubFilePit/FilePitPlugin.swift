//
//  FilePitPlugin.swift
//  PitHubFilePit
//
//  插件入口：/api/file/*、/webdav/*、/s/<token>。
//

import Foundation
import PitHubCore

public final class FilePitPlugin: PitHubPlugin {

    public var id: String { "file" }
    public var displayName: String { "FilePit" }
    public var summary: String { "文件共享 · WebDAV · 分片上传 · 临时分享 · ZIP" }
    public var systemImage: String { "folder.fill" }
    public var apiPrefix: String { "/api/file" }
    public var extraPrefixes: [String] { ["/webdav", "/s"] }
    public var defaultEnabled: Bool { true }

    private weak var host: PitHubPluginHost?
    private var store: FilePitStore?
    private var webdav: FilePitWebDAVHandler?

    public init() {}

    public func attach(host: PitHubPluginHost, dataDirectory: URL) {
        self.host = host
        do {
            let store = try FilePitStore(host: host, dataDirectory: dataDirectory)
            self.store = store
            self.webdav = FilePitWebDAVHandler(store: store)
        } catch {
            PitHubLog.error("FilePit 初始化失败：\(error.localizedDescription)")
        }
    }

    public func handle(_ request: HTTPRequest,
                       subPath: String,
                       context: PitHubPluginRequestContext,
                       respond: @escaping (HTTPResponse) -> Void) {
        guard let store else {
            respond(.error(503, "FilePit 尚未就绪"))
            return
        }

        if request.path == "/webdav" || request.path.hasPrefix("/webdav/") {
            guard let webdav else {
                respond(.error(503, "WebDAV 尚未就绪"))
                return
            }
            webdav.handle(request: request, context: context, respond: respond)
            return
        }

        if request.path == "/s" || request.path.hasPrefix("/s/") {
            let token = subPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !token.isEmpty, !token.contains("/") else {
                respond(.error(404, "分享链接无效"))
                return
            }
            respond(store.shareResponse(token: token, request: request))
            return
        }

        handleAPI(request: request, subPath: subPath, context: context, store: store, respond: respond)
    }

    // MARK: - 网页 API

    private func handleAPI(request: HTTPRequest, subPath: String,
                           context: PitHubPluginRequestContext,
                           store: FilePitStore,
                           respond: @escaping (HTTPResponse) -> Void) {
        var route = subPath
        if route.hasPrefix("/") { route.removeFirst() }
        if route.hasSuffix("/") { route.removeLast() }

        switch route {
        case "roots":
            guard request.method == "GET" else { respond(.error(405, "仅支持 GET")); return }
            let roots = store.availableRoots(role: context.role, settings: context.settings)
            respond(.json(["ok": true, "roots": roots.map { rootJSON($0) }]))

        case "list":
            guard request.method == "GET" else { respond(.error(405, "仅支持 GET")); return }
            perform(respond) {
                let path = request.query["path"] ?? "/"
                let entries = try store.list(path: path, role: context.role, settings: context.settings)
                let roots = store.availableRoots(role: context.role, settings: context.settings)
                let parent = parentPath(for: path) ?? ""
                var payload: [String: Any] = [
                    "ok": true,
                    "path": path,
                    "parent": parent,
                    "entries": entries.map { $0.jsonObject() },
                    "total": entries.count,
                    "roots": roots.map { rootJSON($0) }
                ]
                payload["breadcrumb"] = breadcrumb(path: path)
                var response = HTTPResponse.json(payload)
                response.logAction = "file-list"
                return response
            }

        case "stat":
            guard request.method == "GET" else { respond(.error(405, "仅支持 GET")); return }
            perform(respond) {
                let path = request.query["path"] ?? "/"
                let entry = try store.stat(path: path, role: context.role, settings: context.settings)
                return .json(["ok": true, "entry": entry.jsonObject()])
            }

        case "mkdir":
            perform(respond) {
                guard request.method == "POST" else { return .error(405, "仅支持 POST") }
                let dict = try requireJSON(request)
                let path = try requireString(dict, "path")
                let entry = try store.createFolder(path: path, role: context.role, settings: context.settings)
                var response = HTTPResponse.json(["ok": true, "entry": entry.jsonObject()])
                response.logAction = "mkdir"
                return response
            }

        case "delete":
            perform(respond) {
                guard request.method == "POST" || request.method == "DELETE" else { return .error(405, "仅支持 POST") }
                let dict = try requireJSON(request)
                let path = try requireString(dict, "path")
                try store.delete(path: path, role: context.role, settings: context.settings)
                var response = HTTPResponse.json(["ok": true])
                response.logAction = "delete"
                return response
            }

        case "rename":
            perform(respond) {
                guard request.method == "POST" else { return .error(405, "仅支持 POST") }
                let dict = try requireJSON(request)
                let path = try requireString(dict, "path")
                let name = try requireString(dict, "name")
                let entry = try store.rename(path: path, newName: name, role: context.role, settings: context.settings)
                var response = HTTPResponse.json(["ok": true, "entry": entry.jsonObject()])
                response.logAction = "rename"
                return response
            }

        case "move":
            perform(respond) {
                guard request.method == "POST" else { return .error(405, "仅支持 POST") }
                let dict = try requireJSON(request)
                let path = try requireString(dict, "path")
                let destination = try requireString(dict, "destination")
                let entry = try store.move(path: path, destinationDirectory: destination,
                                           role: context.role, settings: context.settings)
                var response = HTTPResponse.json(["ok": true, "entry": entry.jsonObject()])
                response.logAction = "move"
                return response
            }

        case "upload":
            perform(respond) {
                guard request.method == "POST" || request.method == "PUT" else { return .error(405, "仅支持 POST") }
                guard !request.contentType.lowercased().hasPrefix("multipart/") else {
                    return .error(415, "网页端使用分片上传，不支持 multipart 表单")
                }
                let path = request.query["path"] ?? ""
                guard !path.isEmpty else { return .error(400, "缺少 path 参数") }
                let overwrite = (request.query["overwrite"] ?? "1") == "1"
                let entry = try store.saveUpload(
                    sourceFile: request.bodyFileURL,
                    data: request.body,
                    size: request.bodySize,
                    path: path,
                    role: context.role,
                    settings: context.settings,
                    overwrite: overwrite
                )
                var response = HTTPResponse.json(["ok": true, "entry": entry.jsonObject()])
                response.logAction = "upload"
                return response
            }

        case "upload/init":
            perform(respond) {
                guard request.method == "POST" else { return .error(405, "仅支持 POST") }
                let dict = try requireJSON(request)
                let path = try requireString(dict, "path")
                let size = intValue(dict["size"]) ?? 0
                let session = try store.createUploadSession(path: path, size: Int64(size),
                                                            role: context.role, settings: context.settings)
                var payload = session.jsonObject()
                payload["ok"] = true
                var response = HTTPResponse.json(payload)
                response.logAction = "upload-init"
                return response
            }

        case "upload/chunk":
            perform(respond) {
                guard request.method == "POST" || request.method == "PUT" else { return .error(405, "仅支持 PUT") }
                guard let uploadID = request.query["uploadId"], !uploadID.isEmpty,
                      let index = Int(request.query["index"] ?? "") else {
                    return .error(400, "缺少 uploadId 或 index")
                }
                let session = try store.putChunk(
                    uploadID: uploadID,
                    index: index,
                    sourceFile: request.bodyFileURL,
                    data: request.body,
                    size: request.bodySize,
                    role: context.role,
                    settings: context.settings
                )
                var payload = session.jsonObject()
                payload["ok"] = true
                var response = HTTPResponse.json(payload)
                response.logAction = "upload-chunk"
                return response
            }

        case "upload/complete":
            perform(respond) {
                guard request.method == "POST" else { return .error(405, "仅支持 POST") }
                let dict = try requireJSON(request)
                let uploadID = try requireString(dict, "uploadId")
                let entry = try store.completeUpload(uploadID: uploadID, role: context.role, settings: context.settings)
                var response = HTTPResponse.json(["ok": true, "entry": entry.jsonObject()])
                response.logAction = "upload-complete"
                return response
            }

        case "upload/status":
            guard request.method == "GET" else { respond(.error(405, "仅支持 GET")); return }
            guard let uploadID = request.query["uploadId"], let session = store.uploadStatus(id: uploadID) else {
                respond(.error(404, "上传会话不存在"))
                return
            }
            var payload = session.jsonObject()
            payload["ok"] = true
            respond(.json(payload))

        case "upload/cancel":
            guard request.method == "POST" || request.method == "DELETE" else {
                respond(.error(405, "仅支持 POST"))
                return
            }
            var uploadID = request.query["uploadId"]
            if uploadID == nil, let dict = try? requireJSON(request) {
                uploadID = dict["uploadId"] as? String
            }
            guard let resolvedID = uploadID, !resolvedID.isEmpty else {
                respond(.error(400, "缺少 uploadId"))
                return
            }
            store.cancelUpload(id: resolvedID)
            respond(.json(["ok": true]))

        case "download":
            guard request.method == "GET" || request.method == "HEAD" else {
                respond(.error(405, "仅支持 GET")); return
            }
            let path = request.query["path"] ?? ""
            guard !path.isEmpty else { respond(.error(400, "缺少 path 参数")); return }
            let inline = request.query["inline"] == "1" || request.query["inline"] == "true"
            let resource: PitHubPhotoResource = request.query["live"] == "video" ? .pairedVideo : .original
            store.downloadResponse(path: path, role: context.role, settings: context.settings,
                                   inline: inline, photoResource: resource, completion: respond)

        case "zip":
            guard request.method == "GET" else { respond(.error(405, "仅支持 GET")); return }
            let path = request.query["path"] ?? ""
            guard !path.isEmpty else { respond(.error(400, "缺少 path 参数")); return }
            store.zipResponse(path: path, role: context.role, settings: context.settings, completion: respond)

        case "share":
            perform(respond) {
                guard request.method == "POST" else { return .error(405, "仅支持 POST") }
                guard context.role >= .user else { return .error(403, "访客不能创建分享") }
                let dict = try requireJSON(request)
                let path = try requireString(dict, "path")
                let password = dict["password"] as? String ?? ""
                let minutes = intValue(dict["expiresMinutes"]) ?? context.settings.filePit.shareExpiryMinutes
                let share = try store.createShare(path: path, role: context.role, settings: context.settings,
                                                  password: password, expiresMinutes: minutes)
                let baseURL = (host?.publicURL ?? host?.lanURL ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                var payload: [String: Any] = ["ok": true, "share": share.jsonObject(baseURL: baseURL)]
                var response = HTTPResponse.json(payload)
                response.logAction = "share-create"
                payload["url"] = "\(baseURL)/s/\(share.token)"
                response = HTTPResponse.json(payload)
                return response
            }

        case "shares":
            guard request.method == "GET" else { respond(.error(405, "仅支持 GET")); return }
            guard context.role >= .user else { respond(.error(403, "需要登录权限")); return }
            let baseURL = (host?.publicURL ?? host?.lanURL ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let shares = store.listShares().map { $0.jsonObject(baseURL: baseURL) }
            respond(.json(["ok": true, "shares": shares]))

        case "share/delete":
            perform(respond) {
                guard request.method == "POST" else { return .error(405, "仅支持 POST") }
                guard context.role >= .user else { return .error(403, "需要登录权限") }
                let dict = try requireJSON(request)
                let token = try requireString(dict, "token")
                try store.deleteShare(token: token)
                var response = HTTPResponse.json(["ok": true])
                response.logAction = "share-delete"
                return response
            }

        default:
            respond(.error(404, "未实现的 FilePit 接口：\(route)"))
        }
    }

    // MARK: - 本机预览

    public var isReady: Bool { store != nil }

    public func nativeRoots() -> [FilePitRootInfo] {
        guard let store, let host else { return [] }
        return store.availableRoots(role: .admin, settings: host.settingsSnapshot)
    }

    public func nativeList(path: String) throws -> [FilePitEntry] {
        guard let store, let host else { throw FilePitError.io("FilePit 尚未就绪") }
        return try store.list(path: path, role: .admin, settings: host.settingsSnapshot)
    }

    public func nativeFileURL(path: String) -> URL? {
        guard let store, let host else { return nil }
        return store.localFileURL(path: path, role: .admin, settings: host.settingsSnapshot)
    }

    // MARK: - 工具

    private func perform(_ respond: @escaping (HTTPResponse) -> Void,
                         _ block: () throws -> HTTPResponse) {
        do {
            respond(try block())
        } catch let error as FilePitError {
            respond(error.response())
        } catch {
            respond(.error(500, error.localizedDescription))
        }
    }

    private func requireJSON(_ request: HTTPRequest) throws -> [String: Any] {
        guard let data = request.bodyData(maxBytes: 2 * 1024 * 1024),
              let dict = PitHubJSON.decodeDictionary(data) else {
            throw FilePitError.invalidOperation("请求体不是有效的 JSON")
        }
        return dict
    }

    private func requireString(_ dict: [String: Any], _ key: String) throws -> String {
        guard let value = dict[key] as? String, !value.isEmpty else {
            throw FilePitError.invalidOperation("缺少参数 \(key)")
        }
        return value
    }

    private func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private func parentPath(for path: String) -> String? {
        let comps = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).components(separatedBy: "/")
        guard comps.count > 1 else { return nil }
        return "/" + comps.dropLast().joined(separator: "/")
    }

    private func breadcrumb(path: String) -> [[String: String]] {
        let comps = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).components(separatedBy: "/").filter { !$0.isEmpty }
        var items: [[String: String]] = [["name": "PitHub", "path": "/"]]
        guard !comps.isEmpty else { return items }
        let rootName: String
        switch comps[0].lowercased() {
        case "shared": rootName = "Shared"
        case "uploads": rootName = "Uploads"
        case "private": rootName = "Private"
        case "data": rootName = "Data"
        case "photos": rootName = "Photos"
        default: rootName = comps[0]
        }
        items.append(["name": rootName, "path": "/" + comps[0]])
        var current = "/" + comps[0]
        if comps.count > 1 {
            for index in 1..<comps.count {
                current += "/" + comps[index]
                items.append(["name": comps[index], "path": current])
            }
        }
        return items
    }

    private func rootJSON(_ root: FilePitRootInfo) -> [String: Any] {
        [
            "id": root.id,
            "name": root.name,
            "path": root.path,
            "readOnly": root.readOnly,
            "adminOnly": root.adminOnly,
            "available": root.available
        ]
    }
}
