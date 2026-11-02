//
//  FilePitWebDAV.swift
//  PitHubFilePit
//
//  轻量 WebDAV 实现（不引入第三方库）：
//  OPTIONS / PROPFIND / GET / HEAD / PUT / MKCOL / DELETE / MOVE / COPY /
//  PROPPATCH / LOCK / UNLOCK。
//
//  - 与网页/HTTP API 共用同一套会话与角色：Basic Auth 或 Cookie 均可。
//  - 访客只读；Private / Data 目录仅管理员。
//  - 相机相册（/Photos）只读，底层复用 PhotoKit。
//  - LOCK 仅返回形式化的锁令牌，不做真正的并发互斥（家用场景足够）。
//

import Foundation
import PitHubCore

final class FilePitWebDAVHandler {

    private let store: FilePitStore

    init(store: FilePitStore) {
        self.store = store
    }

    func handle(request: HTTPRequest, context: PitHubPluginRequestContext,
                respond: @escaping (HTTPResponse) -> Void) {
        let method = request.method
        guard let virtualPath = virtualPath(fromWebDAVPath: request.path) else {
            respond(HttpResponseForDAV.error(404, "路径不存在"))
            return
        }

        switch method {
        case "OPTIONS":
            var response = HTTPResponse(status: 200)
            response.headers["DAV"] = "1, 2"
            response.headers["Allow"] = "OPTIONS, GET, HEAD, PROPFIND, PUT, DELETE, MKCOL, MOVE, COPY, PROPPATCH, LOCK, UNLOCK"
            response.headers["MS-Author-Via"] = "DAV"
            response.headers["Content-Length"] = "0"
            respond(response)

        case "PROPFIND":
            handlePropfind(request: request, context: context, virtualPath: virtualPath, respond: respond)

        case "GET", "HEAD":
            handleGet(request: request, context: context, virtualPath: virtualPath, respond: respond)

        case "PUT":
            handlePut(request: request, context: context, virtualPath: virtualPath, respond: respond)

        case "MKCOL":
            handleMkcol(context: context, virtualPath: virtualPath, respond: respond)

        case "DELETE":
            handleDelete(context: context, virtualPath: virtualPath, respond: respond)

        case "MOVE":
            handleMove(request: request, context: context, virtualPath: virtualPath, respond: respond)

        case "COPY":
            respond(HttpResponseForDAV.error(501, "COPY 暂未实现，请在网页端复制/下载后上传"))

        case "PROPPATCH":
            guard context.role >= .user else {
                respond(HttpResponseForDAV.error(403, "访客为只读权限"))
                return
            }
            handleProppatch(virtualPath: virtualPath, respond: respond)

        case "LOCK":
            guard context.role >= .user else {
                respond(HttpResponseForDAV.error(403, "访客为只读权限"))
                return
            }
            handleLock(request: request, virtualPath: virtualPath, respond: respond)

        case "UNLOCK":
            guard context.role >= .user else {
                respond(HttpResponseForDAV.error(403, "访客为只读权限"))
                return
            }
            respond(HTTPResponse(status: 204))

        default:
            respond(HttpResponseForDAV.error(405, "不支持的方法"))
        }
    }

    // MARK: - PROPFIND

    private func handlePropfind(request: HTTPRequest, context: PitHubPluginRequestContext,
                                virtualPath: String, respond: @escaping (HTTPResponse) -> Void) {
        let depthHeader = request.header("depth")?.lowercased() ?? "1"
        let includeChildren = depthHeader != "0"

        do {
            let selfEntry = try store.stat(path: virtualPath, role: context.role, settings: context.settings)
            var items: [(entry: FilePitEntry, href: String)] = [(selfEntry, href(for: virtualPath, isDirectory: selfEntry.isDirectory))]

            if includeChildren, selfEntry.isDirectory {
                let children = try store.list(path: virtualPath, role: context.role, settings: context.settings)
                for child in children.prefix(5000) {
                    items.append((child, href(for: child.path, isDirectory: child.isDirectory)))
                }
            }

            let xml = multistatusXML(items: items)
            var response = HTTPResponse(status: 207, headers: ["Content-Type": "application/xml; charset=utf-8"], body: .data(Data(xml.utf8)))
            response.headers["DAV"] = "1, 2"
            response.logAction = "webdav-propfind"
            respond(response)
        } catch let error as FilePitError {
            respond(HttpResponseForDAV.from(error))
        } catch {
            respond(HttpResponseForDAV.error(500, error.localizedDescription))
        }
    }

    private func multistatusXML(items: [(entry: FilePitEntry, href: String)]) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        xml += "<D:multistatus xmlns:D=\"DAV:\">\n"
        for item in items {
            let entry = item.entry
            let displayName = entry.name.htmlEscaped
            let resourceType = entry.isDirectory ? "<D:collection/>" : ""
            let modified = entry.modified > 0 ? Date(timeIntervalSince1970: entry.modified) : Date()
            let modifiedText = PitHubFormat.httpDate(modified)
            let createdText = PitHubFormat.isoFromSeconds(entry.modified > 0 ? entry.modified : Date().timeIntervalSince1970)
            let contentType = entry.isDirectory ? "httpd/unix-directory" : (entry.mime.isEmpty ? "application/octet-stream" : entry.mime)
            let etag = "\"\(entry.size)-\(Int(entry.modified))\""
            xml += "<D:response>\n"
            xml += "<D:href>\(item.href.htmlEscaped)</D:href>\n"
            xml += "<D:propstat><D:prop>\n"
            xml += "<D:displayname>\(displayName)</D:displayname>\n"
            xml += "<D:resourcetype>\(resourceType)</D:resourcetype>\n"
            xml += "<D:getcontentlength>\(entry.size)</D:getcontentlength>\n"
            xml += "<D:getlastmodified>\(modifiedText)</D:getlastmodified>\n"
            xml += "<D:creationdate>\(createdText)</D:creationdate>\n"
            xml += "<D:getcontenttype>\(contentType)</D:getcontenttype>\n"
            xml += "<D:getetag>\(etag)</D:getetag>\n"
            xml += "</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>\n"
            xml += "</D:response>\n"
        }
        xml += "</D:multistatus>\n"
        return xml
    }

    // MARK: - GET / PUT

    private func handleGet(request: HTTPRequest, context: PitHubPluginRequestContext,
                           virtualPath: String, respond: @escaping (HTTPResponse) -> Void) {
        do {
            let entry = try store.stat(path: virtualPath, role: context.role, settings: context.settings)
            guard !entry.isDirectory else {
                respond(HttpResponseForDAV.error(405, "目录不能用 GET 下载"))
                return
            }
            store.downloadResponse(path: virtualPath, role: context.role, settings: context.settings,
                                   inline: true, photoResource: .original, completion: respond)
        } catch let error as FilePitError {
            respond(HttpResponseForDAV.from(error))
        } catch {
            respond(HttpResponseForDAV.error(500, error.localizedDescription))
        }
    }

    private func handlePut(request: HTTPRequest, context: PitHubPluginRequestContext,
                           virtualPath: String, respond: @escaping (HTTPResponse) -> Void) {
        guard context.role >= .user else {
            respond(HttpResponseForDAV.error(403, "访客为只读权限"))
            return
        }
        guard !virtualPath.hasPrefix("/photos") else {
            respond(HttpResponseForDAV.error(403, "相册目录只读"))
            return
        }
        do {
            let existed = (try? store.stat(path: virtualPath, role: context.role, settings: context.settings)) != nil
            let entry = try store.saveUpload(
                sourceFile: request.bodyFileURL,
                data: request.body,
                size: request.bodySize,
                path: virtualPath,
                role: context.role,
                settings: context.settings,
                overwrite: true
            )
            var response = HTTPResponse(status: existed ? 204 : 201, headers: ["ETag": "\"\(entry.size)-\(Int(entry.modified))\""])
            response.logAction = "webdav-put"
            respond(response)
        } catch let error as FilePitError {
            respond(HttpResponseForDAV.from(error))
        } catch {
            respond(HttpResponseForDAV.error(500, error.localizedDescription))
        }
    }

    // MARK: - 目录操作

    private func handleMkcol(context: PitHubPluginRequestContext, virtualPath: String,
                             respond: @escaping (HTTPResponse) -> Void) {
        guard context.role >= .user else {
            respond(HttpResponseForDAV.error(403, "访客为只读权限"))
            return
        }
        do {
            _ = try store.createFolder(path: virtualPath, role: context.role, settings: context.settings)
            var response = HTTPResponse(status: 201)
            response.headers["Content-Type"] = "application/xml; charset=utf-8"
            response.logAction = "webdav-mkcol"
            respond(response)
        } catch let error as FilePitError {
            respond(HttpResponseForDAV.from(error))
        } catch {
            respond(HttpResponseForDAV.error(500, error.localizedDescription))
        }
    }

    private func handleDelete(context: PitHubPluginRequestContext, virtualPath: String,
                              respond: @escaping (HTTPResponse) -> Void) {
        guard context.role >= .user else {
            respond(HttpResponseForDAV.error(403, "访客为只读权限"))
            return
        }
        do {
            try store.delete(path: virtualPath, role: context.role, settings: context.settings)
            var response = HTTPResponse(status: 204)
            response.logAction = "webdav-delete"
            respond(response)
        } catch let error as FilePitError {
            respond(HttpResponseForDAV.from(error))
        } catch {
            respond(HttpResponseForDAV.error(500, error.localizedDescription))
        }
    }

    private func handleMove(request: HTTPRequest, context: PitHubPluginRequestContext,
                            virtualPath: String, respond: @escaping (HTTPResponse) -> Void) {
        guard context.role >= .user else {
            respond(HttpResponseForDAV.error(403, "访客为只读权限"))
            return
        }
        guard let destinationHeader = request.header("destination"),
              let destination = destinationVirtualPath(destinationHeader) else {
            respond(HttpResponseForDAV.error(400, "缺少 Destination 头"))
            return
        }
        guard destination != virtualPath else {
            respond(HTTPResponse(status: 204))
            return
        }
        let overwrite = (request.header("overwrite") ?? "T").uppercased() != "F"
        do {
            if !overwrite, (try? store.stat(path: destination, role: context.role, settings: context.settings)) != nil {
                respond(HttpResponseForDAV.error(412, "目标已存在且 Overwrite: F"))
                return
            }
            let sourceComponents = components(of: virtualPath)
            let destinationComponents = components(of: destination)
            guard let sourceParent = parentPath(of: sourceComponents),
                  let destinationParent = parentPath(of: destinationComponents),
                  let destinationName = destinationComponents.last else {
                respond(HttpResponseForDAV.error(400, "目标路径无效"))
                return
            }
            if sourceParent == destinationParent {
                _ = try store.rename(path: virtualPath, newName: destinationName,
                                     role: context.role, settings: context.settings)
            } else {
                let moved = try store.move(path: virtualPath, destinationDirectory: destinationParent,
                                           role: context.role, settings: context.settings)
                if moved.name != destinationName {
                    _ = try store.rename(path: moved.path, newName: destinationName,
                                         role: context.role, settings: context.settings)
                }
            }
            var response = HTTPResponse(status: 201, headers: ["Location": href(for: destination, isDirectory: false)])
            response.logAction = "webdav-move"
            respond(response)
        } catch let error as FilePitError {
            respond(HttpResponseForDAV.from(error))
        } catch {
            respond(HttpResponseForDAV.error(500, error.localizedDescription))
        }
    }

    private func handleProppatch(virtualPath: String, respond: @escaping (HTTPResponse) -> Void) {
        let hrefText = href(for: virtualPath, isDirectory: false)
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:"><D:response><D:href>\(hrefText.htmlEscaped)</D:href>
        <D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
        </D:response></D:multistatus>
        """
        var response = HTTPResponse(status: 207, headers: ["Content-Type": "application/xml; charset=utf-8"], body: .data(Data(xml.utf8)))
        response.logAction = "webdav-proppatch"
        respond(response)
    }

    private func handleLock(request: HTTPRequest, virtualPath: String, respond: @escaping (HTTPResponse) -> Void) {
        let token = "urn:uuid:\(UUID().uuidString)"
        let hrefText = href(for: virtualPath, isDirectory: false)
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:prop xmlns:D="DAV:"><D:lockdiscovery><D:activelock>
        <D:locktype><D:write/></D:locktype><D:lockscope><D:exclusive/></D:lockscope>
        <D:depth>infinity</D:depth><D:owner>PitHub</D:owner>
        <D:timeout>Second-3600</D:timeout>
        <D:locktoken><D:href>\(token)</D:href></D:locktoken>
        <D:lockroot><D:href>\(hrefText.htmlEscaped)</D:href></D:lockroot>
        </D:activelock></D:lockdiscovery></D:prop>
        """
        var response = HTTPResponse(status: 200, headers: [
            "Content-Type": "application/xml; charset=utf-8",
            "Lock-Token": "<\(token)>"
        ], body: .data(Data(xml.utf8)))
        response.logAction = "webdav-lock"
        respond(response)
    }

    // MARK: - 路径转换

    private func virtualPath(fromWebDAVPath path: String) -> String? {
        var rest = path
        if rest.hasPrefix("/webdav") {
            rest.removeFirst("/webdav".count)
        }
        rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if rest.isEmpty { return "/" }
        let segments = rest.components(separatedBy: "/")
        guard let first = segments.first else { return nil }
        let rootMap = [
            "shared": "shared", "uploads": "uploads", "private": "private",
            "data": "data", "photos": "photos"
        ]
        guard let rootID = rootMap[first.lowercased()] else { return nil }
        let remaining = Array(segments.dropFirst())
        return "/" + ([rootID] + remaining).joined(separator: "/")
    }

    private func destinationVirtualPath(_ header: String) -> String? {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), !url.path.isEmpty {
            let decoded = url.path.removingPercentEncoding ?? url.path
            return virtualPath(fromWebDAVPath: decoded)
        }
        return virtualPath(fromWebDAVPath: trimmed)
    }

    private func components(of virtualPath: String) -> [String] {
        virtualPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .components(separatedBy: "/")
            .filter { !$0.isEmpty }
    }

    private func parentPath(of components: [String]) -> String? {
        guard components.count > 1 else { return nil }
        return "/" + components.dropLast().joined(separator: "/")
    }

    private func displayName(forRoot rootID: String) -> String {
        switch rootID {
        case "shared": return "Shared"
        case "uploads": return "Uploads"
        case "private": return "Private"
        case "data": return "Data"
        case "photos": return "Photos"
        default: return rootID
        }
    }

    private func href(for virtualPath: String, isDirectory: Bool) -> String {
        let comps = components(of: virtualPath)
        guard let rootID = comps.first else { return "/webdav/" }
        var segments = [displayName(forRoot: rootID)] + comps.dropFirst()
        let encoded = segments.map { $0.urlPathEncoded }.joined(separator: "/")
        var result = "/webdav/" + encoded
        if isDirectory, !result.hasSuffix("/") { result += "/" }
        return result
    }
}

/// WebDAV 错误也返回 JSON，保证状态码与错误信息一致
enum HttpResponseForDAV {
    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        var response = HTTPResponse.json(["ok": false, "error": message], status: status)
        response.headers["DAV"] = "1, 2"
        response.logAction = "webdav-error"
        return response
    }

    static func from(_ error: FilePitError) -> HTTPResponse {
        var response = HTTPResponse.json(
            ["ok": false, "error": error.errorDescription ?? "操作失败"],
            status: error.status
        )
        response.headers["DAV"] = "1, 2"
        response.logAction = "webdav-error"
        return response
    }
}
