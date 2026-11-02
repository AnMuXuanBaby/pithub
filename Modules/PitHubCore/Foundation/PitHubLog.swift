//
//  PitHubLog.swift
//  PitHubCore
//

import Foundation
import os.log

public enum PitHubLog {
    private static let subsystem = "com.pithub.app"
    private static let serverLog = OSLog(subsystem: subsystem, category: "server")
    private static let pluginLog = OSLog(subsystem: subsystem, category: "plugin")

    public static func info(_ message: String) {
        os_log("%{public}@", log: serverLog, type: .info, message)
        #if DEBUG
        print("[PitHub] \(message)")
        #endif
    }

    public static func error(_ message: String) {
        os_log("%{public}@", log: serverLog, type: .error, message)
        #if DEBUG
        print("[PitHub][ERROR] \(message)")
        #endif
    }

    public static func plugin(_ message: String) {
        os_log("%{public}@", log: pluginLog, type: .info, message)
    }
}
