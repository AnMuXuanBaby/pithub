//
//  PitHubZip.swift
//  PitHubCore
//
//  轻量 ZIP 写入器（STORE，无压缩）。
//  为什么不用第三方库：需求要求不引入重型依赖；iOS 没有公开的 ZIP 创建 API。
//  限制：单文件与总大小需小于 4GB（未实现 ZIP64），文档中已标注。
//

import Foundation

public struct PitHubZipEntry {
    public let url: URL
    public let name: String

    public init(url: URL, name: String) {
        self.url = url
        self.name = name
    }
}

public enum PitHubZipError: LocalizedError {
    case tooLarge
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .tooLarge:
            return "目录或单文件超过 4GB，当前 ZIP 写入器未实现 ZIP64，请分批下载。"
        case .unreadable(let name):
            return "无法读取文件：\(name)"
        }
    }
}

public enum PitHubZipWriter {

    private struct CentralRecord {
        let nameData: Data
        let crc: UInt32
        let size: Int64
        let offset: Int64
        let modTime: UInt16
        let modDate: UInt16
    }

    public static func write(entries: [PitHubZipEntry], to zipURL: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: zipURL)
        fm.createFile(atPath: zipURL.path, contents: nil)

        guard let handle = try? FileHandle(forWritingTo: zipURL) else {
            throw PitHubZipError.unreadable(zipURL.lastPathComponent)
        }
        var offset: Int64 = 0
        var central: [CentralRecord] = []

        func write(_ data: Data) throws {
            try handle.write(contentsOf: data)
            offset += Int64(data.count)
        }

        for entry in entries {
            let name = entry.name
            let nameData = Data(name.utf8)
            let attributes = try fm.attributesOfItem(atPath: entry.url.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard size < 0xFFFF_FFFF else { throw PitHubZipError.tooLarge }
            let date = (attributes[.modificationDate] as? Date) ?? Date()
            let (dosTime, dosDate) = dosDateTime(date)

            // 计算 CRC（流式读取，避免整文件进内存）
            var crc: UInt32 = 0xFFFF_FFFF
            var readHandle: FileHandle?
            do {
                readHandle = try FileHandle(forReadingFrom: entry.url)
                while let chunk = try readHandle?.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                    crc = updateCRC(crc, chunk)
                }
            } catch {
                try? readHandle?.close()
                throw PitHubZipError.unreadable(name)
            }
            try? readHandle?.close()
            crc ^= 0xFFFF_FFFF

            let localOffset = offset
            var header = Data()
            header.appendLE32(0x0403_4B50)          // local file header signature
            header.appendLE16(20)                    // version needed
            header.appendLE16(0x0800)                // UTF-8 flag
            header.appendLE16(0)                     // store
            header.appendLE16(dosTime)
            header.appendLE16(dosDate)
            header.appendLE32(crc)
            header.appendLE32(UInt32(size))
            header.appendLE32(UInt32(size))
            header.appendLE16(UInt16(nameData.count))
            header.appendLE16(0)                     // extra length
            header.append(nameData)
            try write(header)

            // 写入文件内容
            if let reader = try? FileHandle(forReadingFrom: entry.url) {
                while let data = try? reader.read(upToCount: 1024 * 1024), !data.isEmpty {
                    try write(data)
                }
                try? reader.close()
            }

            central.append(CentralRecord(nameData: nameData, crc: crc, size: size,
                                         offset: localOffset, modTime: dosTime, modDate: dosDate))
        }

        let centralStart = offset
        for record in central {
            var data = Data()
            data.appendLE32(0x0201_4B50)
            data.appendLE16(0x0014)                  // version made by
            data.appendLE16(20)                      // version needed
            data.appendLE16(0x0800)                  // UTF-8
            data.appendLE16(0)
            data.appendLE16(record.modTime)
            data.appendLE16(record.modDate)
            data.appendLE32(record.crc)
            data.appendLE32(UInt32(record.size))
            data.appendLE32(UInt32(record.size))
            data.appendLE16(UInt16(record.nameData.count))
            data.appendLE16(0)
            data.appendLE16(0)
            data.appendLE16(0)                       // disk number
            data.appendLE16(0)                       // internal attrs
            data.appendLE32(0)                       // external attrs
            data.appendLE32(UInt32(record.offset))
            data.append(record.nameData)
            try write(data)
        }
        let centralSize = offset - centralStart

        var end = Data()
        end.appendLE32(0x0605_4B50)
        end.appendLE16(0)
        end.appendLE16(0)
        end.appendLE16(UInt16(central.count))
        end.appendLE16(UInt16(central.count))
        end.appendLE32(UInt32(centralSize))
        end.appendLE32(UInt32(centralStart))
        end.appendLE16(0)
        try write(end)

        try handle.close()
    }

    // MARK: - CRC32

    private static let crcTable: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    private static func updateCRC(_ crc: UInt32, _ data: Data) -> UInt32 {
        var value = crc
        for byte in data {
            value = (value >> 8) ^ crcTable[Int((value ^ UInt32(byte)) & 0xFF)]
        }
        return value
    }

    // MARK: - DOS 时间

    private static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, min(2107, comps.year ?? 1980))
        let month = max(1, min(12, comps.month ?? 1))
        let day = max(1, min(31, comps.day ?? 1))
        let hour = max(0, min(23, comps.hour ?? 0))
        let minute = max(0, min(59, comps.minute ?? 0))
        let second = max(0, min(59, comps.second ?? 0))
        let time = UInt16((hour << 11) | (minute << 5) | (second / 2))
        let dateValue = UInt16(((year - 1980) << 9) | (month << 5) | day)
        return (time, dateValue)
    }
}

private extension Data {
    mutating func appendLE16(_ value: UInt16) {
        appendByte(UInt8(value & 0xFF))
        appendByte(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLE32(_ value: UInt32) {
        appendByte(UInt8(value & 0xFF))
        appendByte(UInt8((value >> 8) & 0xFF))
        appendByte(UInt8((value >> 16) & 0xFF))
        appendByte(UInt8((value >> 24) & 0xFF))
    }

    mutating func appendByte(_ byte: UInt8) {
        append(byte)
    }
}
