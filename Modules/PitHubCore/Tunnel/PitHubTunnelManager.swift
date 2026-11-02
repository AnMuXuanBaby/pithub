//
//  PitHubTunnelManager.swift
//  PitHubCore
//
//  隧道模块独立于插件：只负责把本机 HTTP 端口暴露到公网，并给出公网地址。
//
//  iOS 沙盒硬性限制（不做绕过）：
//  - App 不能 fork/exec 外部二进制，因此无法在 iPhone 内直接运行 cloudflared。
//  - Cloudflare 模式采用“外部连接器”方案：在路由器 / Mac / NAS 上运行
//    `cloudflared tunnel --url http://<iPhone 局域网 IP>:<端口>`，
//    把得到的公网地址填进设置，App 负责状态检测、二维码与外网流量统计。
//  - 想完全在 App 内一键穿透，请使用 Relay 模式：部署 relay/server.mjs 后，
//    App 主动用 WebSocket 连出去，无需公网 IP，地址自动生成。
//  - frp 同理：外部运行 frpc，App 里填写公网地址即可。
//

import Foundation

public struct PitHubTunnelStatus: Equatable {
    public var provider: PitHubTunnelProvider
    public var active: Bool
    public var publicURL: String?
    public var message: String

    public init(provider: PitHubTunnelProvider, active: Bool, publicURL: String?, message: String) {
        self.provider = provider
        self.active = active
        self.publicURL = publicURL
        self.message = message
    }
}

public final class PitHubTunnelManager {

    public private(set) var status: PitHubTunnelStatus
    public var onUpdate: ((PitHubTunnelStatus) -> Void)?
    public var requestHandler: ((HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void)?

    private var settings: PitHubSettings
    private var relayClient: PitHubRelayTunnelClient?
    private var relaySignature: String = ""
    private var healthTimer: DispatchSourceTimer?
    private var isChecking = false
    private var stopped = true

    public init(settings: PitHubSettings) {
        self.settings = settings
        self.status = PitHubTunnelStatus(
            provider: settings.tunnelProvider,
            active: false,
            publicURL: nil,
            message: "仅局域网模式"
        )
    }

    public var publicURL: String? {
        status.active ? status.publicURL : nil
    }

    public var isActive: Bool { status.active }

    // MARK: - 配置

    public func apply(settings newSettings: PitHubSettings) {
        settings = newSettings
        stopped = false
        healthTimer?.cancel()
        healthTimer = nil

        guard newSettings.tunnelEnabled else {
            stopRelay()
            update(PitHubTunnelStatus(provider: newSettings.tunnelProvider, active: false,
                                      publicURL: nil, message: "仅局域网模式"))
            return
        }

        switch newSettings.tunnelProvider {
        case .none:
            stopRelay()
            update(PitHubTunnelStatus(provider: .none, active: false,
                                      publicURL: nil, message: "仅局域网模式"))

        case .relay:
            let signature = "\(newSettings.relayURL)|\(newSettings.relayToken)|\(newSettings.bonjourName)"
            if relayClient != nil, relaySignature == signature {
                // 参数没变，保持现有连接
                return
            }
            stopRelay()
            guard let url = URL(string: newSettings.relayURL.trimmed),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https", "ws", "wss"].contains(scheme),
                  !newSettings.relayToken.isEmpty else {
                update(PitHubTunnelStatus(provider: .relay, active: false, publicURL: nil,
                                          message: "请先在设置里填写 Relay 地址（http/https/ws/wss）与 Token（部署 relay/server.mjs）"))
                return
            }
            relaySignature = signature
            let client = PitHubRelayTunnelClient(relayURL: url, token: newSettings.relayToken, name: newSettings.bonjourName)
            client.onReady = { [weak self] publicURL in
                guard let self else { return }
                let normalized = publicURL.hasSuffix("/") ? publicURL : publicURL + "/"
                self.update(PitHubTunnelStatus(provider: .relay, active: true, publicURL: normalized,
                                               message: "Relay 隧道已建立"))
            }
            client.onStateChange = { [weak self] message in
                guard let self, let message else { return }
                self.update(PitHubTunnelStatus(provider: .relay, active: false,
                                               publicURL: nil, message: message))
            }
            client.onRequest = { [weak self] request, respond in
                guard let self, let handler = self.requestHandler else {
                    respond(.error(503, "本地服务未就绪"))
                    return
                }
                handler(request, respond)
            }
            relayClient = client
            update(PitHubTunnelStatus(provider: .relay, active: false, publicURL: nil,
                                      message: "正在连接 Relay…"))
            client.start()

        case .cloudflare, .frp:
            stopRelay()
            let provider = newSettings.tunnelProvider
            let raw = newSettings.tunnelPublicURL.trimmed
            guard !raw.isEmpty, let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else {
                let hint = provider == .cloudflare
                    ? "Cloudflare 模式需要外部连接器：在电脑/路由器运行 cloudflared 指向本机端口，然后在这里填写公网地址"
                    : "frp 模式需要在外部运行 frpc，然后在这里填写公网地址"
                update(PitHubTunnelStatus(provider: provider, active: false, publicURL: nil, message: hint))
                return
            }
            let normalized = raw.hasSuffix("/") ? raw : raw + "/"
            update(PitHubTunnelStatus(provider: provider, active: false, publicURL: normalized,
                                      message: "正在检测公网地址…"))
            verifyExternalTunnel(normalized)
            startHealthTimer(normalized)
        }
    }

    public func stop() {
        stopped = true
        healthTimer?.cancel()
        healthTimer = nil
        stopRelay()
        update(PitHubTunnelStatus(provider: settings.tunnelProvider, active: false,
                                  publicURL: nil, message: "隧道已停止"))
    }

    private func stopRelay() {
        relayClient?.stop()
        relayClient = nil
        relaySignature = ""
    }

    // MARK: - 外部连接器检测

    private func startHealthTimer(_ baseURL: String) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            self.verifyExternalTunnel(baseURL)
        }
        timer.resume()
        healthTimer = timer
    }

    private func verifyExternalTunnel(_ baseURL: String) {
        var base = baseURL
        if base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/api/health") else {
            update(PitHubTunnelStatus(provider: settings.tunnelProvider, active: false,
                                      publicURL: baseURL, message: "公网地址格式不正确"))
            return
        }
        guard !isChecking else { return }
        isChecking = true

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("PitHub-Tunnel-Check", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { [weak self] _, response, error in
            session.invalidateAndCancel()
            guard let self else { return }
            self.isChecking = false
            guard !self.stopped else { return }
            if let error {
                self.update(PitHubTunnelStatus(provider: self.settings.tunnelProvider, active: false,
                                               publicURL: baseURL,
                                               message: "公网地址暂不可达：\(error.localizedDescription)"))
                return
            }
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                self.update(PitHubTunnelStatus(provider: self.settings.tunnelProvider, active: true,
                                               publicURL: baseURL, message: "公网隧道可用"))
            } else {
                self.update(PitHubTunnelStatus(provider: self.settings.tunnelProvider, active: false,
                                               publicURL: baseURL, message: "公网地址返回异常，请检查连接器"))
            }
        }.resume()
    }

    // MARK: - 状态通知

    private func update(_ newStatus: PitHubTunnelStatus) {
        status = newStatus
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(newStatus)
        }
    }

    public func jsonObject() -> [String: Any] {
        [
            "provider": status.provider.rawValue,
            "providerName": status.provider.displayName,
            "active": status.active,
            "publicURL": status.publicURL ?? "",
            "message": status.message
        ]
    }

    // MARK: - 外部连接器配置生成

    public static func cloudflareCommand(port: UInt16) -> String {
        """
        # 在 Mac / Linux / NAS 上执行（iPhone 与它需在同一 Wi-Fi）：
        brew install cloudflared   # 或按官网下载
        cloudflared tunnel --url http://<iPhone 的局域网 IP>:\(port)
        # 终端会输出一个 https://xxxx.trycloudflare.com 地址，
        # 把它填到 PitHub 设置 → 外网隧道 → 公网地址。
        # 想要固定域名：cloudflared tunnel create pithub && cloudflared tunnel route dns ...
        """
    }

    public static func frpConfig(serverAddress: String, serverPort: Int, token: String, iphoneIP: String, localPort: UInt16) -> String {
        """
        # frpc.ini / frpc.toml（在路由器或电脑上运行）
        serverAddr = "\(serverAddress)"
        serverPort = \(serverPort)
        auth.token = "\(token)"

        [[proxies]]
        name = "pithub"
        type = "http"
        localIP = "\(iphoneIP)"
        localPort = \(localPort)
        customDomains = ["pithub.yourdomain.com"]
        """
    }
}
