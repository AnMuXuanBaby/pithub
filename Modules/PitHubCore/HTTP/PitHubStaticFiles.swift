//
//  PitHubStaticFiles.swift
//  PitHubCore
//
//  托管内嵌在 App Bundle 里的 www 目录（纯静态 HTML/CSS/JS）。
//  也允许把 www 放到 Documents/PitHub/www 覆盖，方便调试。
//

import Foundation

public final class PitHubWebAssets {

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// 查找 www 目录：环境变量 > Documents 覆盖 > Bundle/www > Bundle/frontend
    public static func locate() -> PitHubWebAssets? {
        let fm = FileManager.default
        var candidates: [URL] = []

        if let override = ProcessInfo.processInfo.environment["PITHUB_WWW"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        candidates.append(PitHubPaths.documentsRoot.appendingPathComponent("www", isDirectory: true))

        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("www", isDirectory: true))
            candidates.append(resourceURL.appendingPathComponent("frontend", isDirectory: true))
            candidates.append(resourceURL)
        }

        for candidate in candidates {
            let index = candidate.appendingPathComponent("index.html")
            if fm.fileExists(atPath: index.path) {
                return PitHubWebAssets(root: candidate)
            }
        }
        return nil
    }

    public var indexURL: URL {
        root.appendingPathComponent("index.html")
    }

    /// path 形如 "/assets/app.css"，返回 nil 表示未找到
    public func response(for path: String) -> HTTPResponse? {
        guard let relative = PitHubPathGuard.normalizedRelativePath(path), !relative.isEmpty else {
            return nil
        }
        // 只允许访问根目录内的普通文件
        guard let target = PitHubPathGuard.safeJoin(base: root, relative: relative) else {
            return nil
        }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: target.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }

        let isHTML = target.pathExtension.lowercased() == "html"
        var response = HTTPResponse.file(
            url: target,
            contentType: PitHubMIME.type(for: target.lastPathComponent),
            supportsRange: true,
            action: "static"
        )
        response.headers["Cache-Control"] = isHTML ? "no-cache" : "public, max-age=3600"
        return response
    }

    public func indexResponse() -> HTTPResponse? {
        response(for: "index.html")
    }
}
