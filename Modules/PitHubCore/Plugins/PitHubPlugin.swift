//
//  PitHubPlugin.swift
//  PitHubCore
//
//  插件协议：主程序只是骨架，功能全部通过插件挂载。
//  每个插件声明自己的 API 前缀（/api/file）与额外挂载点（/webdav、/s）。
//

import Foundation

public struct PitHubPluginRequestContext {
    public let role: PitHubRole
    public let settings: PitHubSettings
    public let remoteAddress: String
    public let isTunnel: Bool
    public let requestID: String
    public let sessionToken: String?

    public init(role: PitHubRole,
                settings: PitHubSettings,
                remoteAddress: String,
                isTunnel: Bool,
                requestID: String,
                sessionToken: String?) {
        self.role = role
        self.settings = settings
        self.remoteAddress = remoteAddress
        self.isTunnel = isTunnel
        self.requestID = requestID
        self.sessionToken = sessionToken
    }
}

public protocol PitHubPluginHost: AnyObject {
    var settingsSnapshot: PitHubSettings { get }
    var shareBaseURL: String { get }
    var photoLibrary: PitHubPhotoLibrary { get }
    var cache: PitHubLRUCache { get }
    var thumbnailCache: PitHubLRUCache { get }
    var notifier: PitHubNotifier { get }
    var accessLog: PitHubAccessLogStore { get }
    var lanURL: String { get }
    var publicURL: String? { get }
    func updateSettings(_ mutate: (inout PitHubSettings) -> Void)
    func runOnMain(_ block: @escaping () -> Void)
}

public protocol PitHubPlugin: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var summary: String { get }
    /// SF Symbol 名称，App 本机 UI 使用
    var systemImage: String { get }
    /// 例如 /api/file
    var apiPrefix: String { get }
    /// 额外挂载点，例如 ["/webdav", "/s"]
    var extraPrefixes: [String] { get }
    var defaultEnabled: Bool { get }

    func attach(host: PitHubPluginHost, dataDirectory: URL)
    func handle(_ request: HTTPRequest,
                subPath: String,
                context: PitHubPluginRequestContext,
                respond: @escaping (HTTPResponse) -> Void)
}

public struct PitHubPluginDescriptor: Identifiable, Codable, Equatable {
    public var id: String
    public var name: String
    public var summary: String
    public var systemImage: String
    public var prefix: String
    public var enabled: Bool
    public var defaultEnabled: Bool
}
