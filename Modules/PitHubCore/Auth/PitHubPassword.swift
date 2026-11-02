//
//  PitHubPassword.swift
//  PitHubCore
//
//  加盐密码哈希。CryptoKit 没有直接提供 PBKDF2，这里用一个固定轮数的
//  迭代 SHA-256 变体来做慢哈希（非密码学上最理想，但足以应对家用场景，
//  且完全使用公开 API）。文档中已标注这一点。
//

import Foundation
import CryptoKit
import Security

public enum PitHubPassword {

    private static let iterations = 6000

    public static func makeSalt() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if result != errSecSuccess {
            for index in 0..<bytes.count { bytes[index] = UInt8.random(in: 0...255) }
        }
        return Data(bytes).base64EncodedString()
    }

    public static func hash(_ password: String, salt: String) -> String {
        let saltData = Data(salt.utf8)
        var digest = SHA256.hash(data: saltData + Data(password.utf8))
        var digestData = Data(digest)
        for _ in 0..<iterations {
            digest = SHA256.hash(data: digestData + saltData)
            digestData = Data(digest)
        }
        return digestData.base64EncodedString()
    }

    public static func verify(_ password: String, salt: String, hash expected: String) -> Bool {
        guard !salt.isEmpty, !expected.isEmpty else { return false }
        let actual = hash(password, salt: salt)
        return constantTimeEqual(actual, expected)
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var result: UInt8 = 0
        for index in 0..<a.count {
            result |= a[index] ^ b[index]
        }
        return result == 0
    }
}
