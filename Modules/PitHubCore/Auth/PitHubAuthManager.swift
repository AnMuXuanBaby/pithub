//
//  PitHubAuthManager.swift
//  PitHubCore
//
//  统一鉴权：网页、API、WebDAV 共用同一套会话/角色模型。
//  - 会话 Cookie: pithub_session
//  - 也支持 Authorization: Bearer <token>（方便独立部署的前端）
//  - WebDAV 支持 HTTP Basic（用户名 admin 表示管理员，其余为普通用户）
//

import Foundation
import Security

public enum PitHubRole: String, Codable, CaseIterable, Comparable, Hashable {
    case guest
    case user
    case admin

    public var level: Int {
        switch self {
        case .guest: return 0
        case .user: return 1
        case .admin: return 2
        }
    }

    public var displayName: String {
        switch self {
        case .guest: return "访客"
        case .user: return "用户"
        case .admin: return "管理员"
        }
    }

    public static func < (lhs: PitHubRole, rhs: PitHubRole) -> Bool {
        lhs.level < rhs.level
    }
}

public struct PitHubSession: Codable, Equatable {
    public let token: String
    public let role: PitHubRole
    public let createdAt: Date
    public var expiresAt: Date
    public let remembered: Bool
}

public final class PitHubAuthManager {

    public static let cookieName = "pithub_session"

    private let lock = NSLock()
    private var sessions: [String: PitHubSession] = [:]
    private var timeoutSeconds: TimeInterval = 720 * 60
    private let persistenceURL: URL?
    private let settingsProvider: () -> PitHubSettings

    public init(settingsProvider: @escaping () -> PitHubSettings,
                persistenceURL: URL? = PitHubPaths.config.appendingPathComponent("sessions.json")) {
        self.settingsProvider = settingsProvider
        self.persistenceURL = persistenceURL
        loadPersisted()
        refreshTimeout()
    }

    public func refreshTimeout() {
        let minutes = settingsProvider().sessionTimeoutMinutes
        lock.lock()
        timeoutSeconds = TimeInterval(max(5, min(60 * 24 * 30, minutes)) * 60)
        lock.unlock()
    }

    public var sessionTimeoutSeconds: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return timeoutSeconds
    }

    // MARK: - 登录

    @discardableResult
    public func login(role: PitHubRole, password: String, remember: Bool) -> PitHubSession? {
        let settings = settingsProvider()
        switch role {
        case .guest:
            guard settings.guestEnabled else { return nil }
        case .user:
            guard PitHubPassword.verify(password, salt: settings.accessPasswordSalt, hash: settings.accessPasswordHash) else {
                return nil
            }
        case .admin:
            let salt = settings.adminPasswordHash.isEmpty ? settings.accessPasswordSalt : settings.adminPasswordSalt
            let hash = settings.adminPasswordHash.isEmpty ? settings.accessPasswordHash : settings.adminPasswordHash
            guard PitHubPassword.verify(password, salt: salt, hash: hash) else { return nil }
        }

        let token = Self.randomToken()
        let session = PitHubSession(
            token: token,
            role: role,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(sessionTimeoutSeconds),
            remembered: remember
        )
        lock.lock()
        sessions[token] = session
        lock.unlock()
        persist()
        return session
    }

    // MARK: - 校验

    public func role(forToken token: String) -> PitHubRole? {
        lock.lock()
        defer { lock.unlock() }
        guard var session = sessions[token] else { return nil }
        if session.expiresAt <= Date() {
            sessions.removeValue(forKey: token)
            return nil
        }
        // 活跃使用会顺延会话（空闲超时）
        session.expiresAt = Date().addingTimeInterval(timeoutSeconds)
        sessions[token] = session
        return session.role
    }

    public func authenticate(cookieToken: String?, bearer: String?, basic: String?, settings: PitHubSettings) -> PitHubRole? {
        if let token = cookieToken ?? bearer, !token.isEmpty, let role = role(forToken: token) {
            return role
        }
        if let basic, let credentials = Self.decodeBasic(basic) {
            let username = credentials.username.lowercased()
            if username == "admin" {
                let salt = settings.adminPasswordHash.isEmpty ? settings.accessPasswordSalt : settings.adminPasswordSalt
                let hash = settings.adminPasswordHash.isEmpty ? settings.accessPasswordHash : settings.adminPasswordHash
                if PitHubPassword.verify(credentials.password, salt: salt, hash: hash) {
                    return .admin
                }
                return nil
            }
            if PitHubPassword.verify(credentials.password, salt: settings.accessPasswordSalt, hash: settings.accessPasswordHash) {
                return .user
            }
        }
        return nil
    }

    public func logout(token: String) {
        lock.lock()
        sessions.removeValue(forKey: token)
        lock.unlock()
        persist()
    }

    public func logoutAll() {
        lock.lock()
        sessions.removeAll()
        lock.unlock()
        persist()
    }

    public func cleanupExpired() {
        let now = Date()
        lock.lock()
        sessions = sessions.filter { $0.value.expiresAt > now }
        lock.unlock()
    }

    // MARK: - 持久化

    private func loadPersisted() {
        guard let url = persistenceURL,
              let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([PitHubSession].self, from: data) else { return }
        let now = Date()
        let valid = decoded.filter { $0.expiresAt > now && $0.remembered }
        sessions = Dictionary(uniqueKeysWithValues: valid.map { ($0.token, $0) })
    }

    private func persist() {
        guard let url = persistenceURL else { return }
        let snapshot: [PitHubSession]
        lock.lock()
        snapshot = sessions.values.filter { $0.remembered }
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            do {
                try PitHubPaths.ensureDirectory(url.deletingLastPathComponent())
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                PitHubLog.error("会话保存失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 工具

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            for index in 0..<bytes.count { bytes[index] = UInt8.random(in: 0...255) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBasic(_ header: String) -> (username: String, password: String)? {
        let value = header.trimmingCharacters(in: .whitespaces)
        guard value.lowercased().hasPrefix("basic ") else { return nil }
        let base64 = String(value.dropFirst(6))
        guard let data = Data(base64Encoded: base64),
              let decoded = String(data: data, encoding: .utf8),
              let colon = decoded.firstIndex(of: ":") else { return nil }
        let username = String(decoded[..<colon])
        let password = String(decoded[decoded.index(after: colon)...])
        return (username, password)
    }
}
