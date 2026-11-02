//
//  PitHubNetworkInfo.swift
//  PitHubCore
//
//  读取本机局域网 IP（getifaddrs，公开 API），用于生成访问地址与二维码。
//

import Foundation
import Darwin

public enum PitHubNetworkInfo {

    public struct Interface: Equatable {
        public let name: String
        public let address: String
    }

    public static func ipv4Interfaces() -> [Interface] {
        var result: [Interface] = []
        var addrsPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrsPointer) == 0, let first = addrsPointer else { return [] }
        defer { freeifaddrs(first) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let addrs = current.pointee
            defer { pointer = addrs.ifa_next }
            guard let sockaddrPointer = addrs.ifa_addr else { continue }
            guard sockaddrPointer.pointee.sa_family == UInt8(AF_INET) else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = sockaddrPointer.pointee.sa_len
            let code = getnameinfo(
                sockaddrPointer,
                socklen_t(length),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard code == 0 else { continue }
            let address = String(cString: hostname)
            if address.isEmpty || address.hasPrefix("127.") || address.hasPrefix("169.254.") { continue }
            let name = String(cString: addrs.ifa_name)
            result.append(Interface(name: name, address: address))
        }
        return result
    }

    /// 优先 en0（Wi-Fi），其次任意非回环 IPv4。
    public static func primaryIPv4() -> String? {
        let interfaces = ipv4Interfaces()
        if let wifi = interfaces.first(where: { $0.name == "en0" }) { return wifi.address }
        return interfaces.first?.address
    }

    public static func hostName() -> String {
        ProcessInfo.processInfo.hostName
    }

    public static func urlString(host: String, port: UInt16) -> String {
        "http://\(host):\(port)"
    }
}
