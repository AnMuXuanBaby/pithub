//
//  FilePitStore.swift
//  PitHubFilePit
//
//  文件虚拟根 + 增量目录缓存 + 分片上传 + 临时分享 + ZIP。
//
//  虚拟路径：
//    /shared   Documents/PitHub/Shared      （用户可读写，访客可读）
//    /uploads  Documents/PitHub/Uploads     （用户可读写）
//    /private  Application Support/Private  （仅管理员）
//    /data     PluginData/FilePit           （仅管理员）
//    /photos   系统相册（只读，复用 PhotoNode 的 PhotoKit 服务）
//
//  沙盒限制：iOS 无法获得相册文件的真实路径，相册下载只能先导出到临时目录，
//  再通过 HTTP 流式下发。文档中已标注。
//

import Foundation
import PitHubCore

final class FilePitStore {

    private struct RootDefinition {
        let id: String
        let name: String
        let readOnly: Bool
        let adminOnly: Bool
        let needsPhotoMount: Bool
    }

    private static let rootDefinitions: [RootDefinition] = [
        RootDefinition(id: "shared", name: "Shared", readOnly: false, adminOnly: false, needsPhotoMount: false),
        RootDefinition(id: "uploads", name: "Uploads", readOnly: false, adminOnly: false, needsPhotoMount: false),
        RootDefinition(id: "private", name: "Private", readOnly: false, adminOnly: true, needsPhotoMount: false),
        RootDefinition(id: "data", name: "Data", readOnly: false, adminOnly: true, needsPhotoMount: false),
        RootDefinition(id: "photos", name: "Photos", readOnly: true, adminOnly: false, needsPhotoMount: true)
    ]

    private struct FSLocation {
        let rootID: String
        let url: URL
        let relative: String
        let virtualPath: String
        let readOnly: Bool
    }

    private struct CachedListing {
        let mtime: Date
        let entries: [FilePitEntry]
    }

    private weak var host: PitHubPluginHost?
    private let dataDirectory: URL
    private let uploadDirectory: URL
    private let exportDirectory: URL
    private let shareFileURL: URL
    private let lock = NSLock()

    private var listingCache: [String: CachedListing] = [:]
    private var photoCache: [String: (date: Date, entries: [FilePitEntry])] = [:]
    private var shares: [FilePitShare] = []
    private var uploadSessions: [String: FilePitUploadSession] = [:]

    init(host: PitHubPluginHost, dataDirectory: URL) throws {
        self.host = host
        self.dataDirectory = dataDirectory
        self.uploadDirectory = dataDirectory.appendingPathComponent("upload-sessions", isDirectory: true)
        self.exportDirectory = dataDirectory.appendingPathComponent("exports", isDirectory: true)
        self.shareFileURL = dataDirectory.appendingPathComponent("shares.json")

        try PitHubPaths.ensureDirectory(dataDirectory)
        try PitHubPaths.ensureDirectory(uploadDirectory)
        try PitHubPaths.ensureDirectory(exportDirectory)
        try PitHubPaths.ensureDirectory(PitHubPaths.sharedRoot)
        try PitHubPaths.ensureDirectory(PitHubPaths.uploadsRoot)
        try PitHubPaths.ensureDirectory(PitHubPaths.privateRoot)

        loadShares()
        loadUploadSessions()
        cleanupStaleUploads()
        cleanupExpiredShares()
        cleanupExports()
    }

    // MARK: - 根目录

    func availableRoots(role: PitHubRole, settings: PitHubSettings) -> [FilePitRootInfo] {
        Self.rootDefinitions.compactMap { definition in
            guard !definition.needsPhotoMount || settings.filePit.allowPhotoMount else { return nil }
            guard !definition.adminOnly || role == .admin else { return nil }
            let writable = canWrite(rootID: definition.id, role: role)
            return FilePitRootInfo(
                id: definition.id,
                name: definition.name,
                path: "/\(definition.id)",
                readOnly: definition.readOnly || !writable,
                adminOnly: definition.adminOnly,
                available: true
            )
        }
    }

    private func definition(for rootID: String) -> RootDefinition? {
        Self.rootDefinitions.first { $0.id == rootID }
    }

    private func baseURL(for rootID: String) -> URL? {
        switch rootID {
        case "shared": return PitHubPaths.sharedRoot
        case "uploads": return PitHubPaths.uploadsRoot
        case "private": return PitHubPaths.privateRoot
        case "data": return dataDirectory
        default: return nil
        }
    }

    private func canWrite(rootID: String, role: PitHubRole) -> Bool {
        guard let definition = definition(for: rootID) else { return false }
        guard role >= .user else { return false }
        guard !definition.readOnly else { return false }
        if definition.adminOnly { return role == .admin }
        return true
    }

    private func requireReadAccess(rootID: String, role: PitHubRole) throws {
        guard let definition = definition(for: rootID) else { throw FilePitError.notFound("目录不存在") }
        if definition.adminOnly, role != .admin {
            throw FilePitError.forbidden("该目录仅管理员可访问")
        }
    }

    // MARK: - 路径解析

    private func split(_ path: String) -> [String] {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return [] }
        let parts = trimmed.components(separatedBy: "/").filter { !$0.isEmpty }
        return parts
    }

    private func resolveFS(path: String, role: PitHubRole, settings: PitHubSettings, write: Bool) throws -> FSLocation {
        let components = split(path)
        guard let rootID = components.first?.lowercased(), let definition = definition(for: rootID) else {
            throw FilePitError.invalidPath
        }
        if definition.needsPhotoMount, !settings.filePit.allowPhotoMount {
            throw FilePitError.notFound("相册挂载未开启")
        }
        guard let base = baseURL(for: rootID) else {
            throw FilePitError.notFound("目录不存在")
        }
        try requireReadAccess(rootID: rootID, role: role)
        if write {
            guard canWrite(rootID: rootID, role: role) else {
                throw definition.adminOnly ? FilePitError.forbidden("该目录仅管理员可写") : FilePitError.forbidden("当前角色只读")
            }
        }
        let relative = components.dropFirst().joined(separator: "/")
        guard let url = PitHubPathGuard.safeJoin(base: base, relative: relative) else {
            throw FilePitError.invalidPath
        }
        return FSLocation(
            rootID: rootID,
            url: url,
            relative: relative,
            virtualPath: components.isEmpty ? "/\(rootID)" : "/" + components.joined(separator: "/"),
            readOnly: !canWrite(rootID: rootID, role: role)
        )
    }

    // MARK: - 列表

    func list(path: String, role: PitHubRole, settings: PitHubSettings) throws -> [FilePitEntry] {
        let components = split(path)
        if components.isEmpty {
            return rootEntries(role: role, settings: settings)
        }
        if components[0].lowercased() == "photos" {
            return try listPhotos(components: Array(components.dropFirst()), role: role, settings: settings)
        }
        let location = try resolveFS(path: path, role: role, settings: settings, write: false)
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: location.url.path, isDirectory: &isDirectory) else {
            throw FilePitError.notFound("目录不存在")
        }
        if isDirectory.boolValue {
            return try directoryListing(location, role: role, settings: settings)
        }
        return [try entry(url: location.url, virtualPath: location.virtualPath, rootID: location.rootID, readOnly: location.readOnly)]
    }

    func localFileURL(path: String, role: PitHubRole, settings: PitHubSettings) -> URL? {
        let components = split(path)
        guard components.first?.lowercased() != "photos" else { return nil }
        guard let location = try? resolveFS(path: path, role: role, settings: settings, write: false) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: location.url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return location.url
    }

    func stat(path: String, role: PitHubRole, settings: PitHubSettings) throws -> FilePitEntry {
        let components = split(path)
        if components.isEmpty {
            return FilePitEntry(name: "PitHub", path: "/", isDirectory: true, kind: "folder", rootID: "")
        }
        if components[0].lowercased() == "photos" {
            return try photoStat(components: Array(components.dropFirst()), role: role, settings: settings)
        }
        let location = try resolveFS(path: path, role: role, settings: settings, write: false)
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: location.url.path, isDirectory: &isDirectory) else {
            throw FilePitError.notFound("文件不存在")
        }
        let displayName: String
        if location.relative.isEmpty {
            displayName = definition(for: location.rootID)?.name ?? location.rootID
        } else {
            displayName = (location.relative as NSString).lastPathComponent
        }
        return try entry(url: location.url, virtualPath: location.virtualPath, rootID: location.rootID,
                         readOnly: location.readOnly, displayName: displayName, isDirectory: isDirectory.boolValue)
    }

    private func rootEntries(role: PitHubRole, settings: PitHubSettings) -> [FilePitEntry] {
        availableRoots(role: role, settings: settings).map { root in
            FilePitEntry(
                name: root.name,
                path: root.path,
                isDirectory: true,
                kind: "folder",
                mime: "inode/directory",
                isReadOnly: root.readOnly,
                rootID: root.id
            )
        }
    }

    private func directoryListing(_ location: FSLocation, role: PitHubRole, settings: PitHubSettings) throws -> [FilePitEntry] {
        let fm = FileManager.default
        let attributes = try? fm.attributesOfItem(atPath: location.url.path)
        let mtime = (attributes?[.modificationDate] as? Date) ?? Date.distantPast
        // 缓存键包含角色，避免管理员看到“可写”、访客看到同一份缓存里的“可写”标记
        let cacheKey = location.url.path + "#" + role.rawValue

        lock.lock()
        if let cached = listingCache[cacheKey], cached.mtime == mtime {
            lock.unlock()
            return cached.entries
        }
        lock.unlock()

        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        let contents = try fm.contentsOfDirectory(at: location.url, includingPropertiesForKeys: keys, options: [])
        var entries: [FilePitEntry] = []
        entries.reserveCapacity(contents.count)

        let parentVirtual = location.virtualPath
        for url in contents {
            let name = url.lastPathComponent
            if name == ".DS_Store" { continue }
            let childVirtual = parentVirtual + "/" + name
            if let entry = try? entry(url: url, virtualPath: childVirtual, rootID: location.rootID, readOnly: location.readOnly) {
                entries.append(entry)
            }
        }
        entries.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        lock.lock()
        if listingCache.count > 400 { listingCache.removeAll() }
        listingCache[cacheKey] = CachedListing(mtime: mtime, entries: entries)
        lock.unlock()
        return entries
    }

    private func entry(url: URL,
                       virtualPath: String,
                       rootID: String,
                       readOnly: Bool,
                       displayName: String? = nil,
                       isDirectory forcedDirectory: Bool? = nil) throws -> FilePitEntry {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey])
        let isDirectory = forcedDirectory ?? (values.isDirectory ?? false)
        let name = displayName ?? url.lastPathComponent
        let size = isDirectory ? 0 : Int64(values.fileSize ?? 0)
        let modified = (values.contentModificationDate ?? Date.distantPast).timeIntervalSince1970
        let mime = isDirectory ? "inode/directory" : PitHubMIME.type(for: name)
        let kind = isDirectory ? "folder" : PitHubMIME.kind(for: name)
        return FilePitEntry(
            name: name,
            path: virtualPath,
            isDirectory: isDirectory,
            size: size,
            modified: modified,
            kind: kind,
            mime: mime,
            isReadOnly: readOnly,
            rootID: rootID
        )
    }

    // MARK: - 文件操作

    @discardableResult
    func createFolder(path: String, role: PitHubRole, settings: PitHubSettings) throws -> FilePitEntry {
        let location = try resolveFS(path: path, role: role, settings: settings, write: true)
        guard !location.relative.isEmpty else { throw FilePitError.invalidOperation("不能在根目录创建同名文件夹") }
        let fm = FileManager.default
        if fm.fileExists(atPath: location.url.path) {
            throw FilePitError.conflict("同名文件或文件夹已存在")
        }
        try fm.createDirectory(at: location.url, withIntermediateDirectories: false)
        invalidate(location.url.deletingLastPathComponent())
        return try entry(url: location.url, virtualPath: location.virtualPath, rootID: location.rootID, readOnly: location.readOnly)
    }

    func delete(path: String, role: PitHubRole, settings: PitHubSettings) throws {
        let location = try resolveFS(path: path, role: role, settings: settings, write: true)
        guard !location.relative.isEmpty else { throw FilePitError.invalidOperation("不能删除挂载根目录") }
        let fm = FileManager.default
        guard fm.fileExists(atPath: location.url.path) else { throw FilePitError.notFound("文件不存在") }
        try fm.removeItem(at: location.url)
        invalidate(location.url)
        invalidate(location.url.deletingLastPathComponent())
    }

    @discardableResult
    func rename(path: String, newName: String, role: PitHubRole, settings: PitHubSettings) throws -> FilePitEntry {
        let location = try resolveFS(path: path, role: role, settings: settings, write: true)
        guard !location.relative.isEmpty else { throw FilePitError.invalidOperation("不能重命名挂载根目录") }
        let cleanName = newName.sanitizedFileName
        guard !cleanName.isEmpty else { throw FilePitError.invalidOperation("名称不能为空") }
        let parent = location.url.deletingLastPathComponent()
        let target = parent.appendingPathComponent(cleanName)
        guard PitHubPathGuard.isSubpath(target, of: parent) else { throw FilePitError.invalidPath }
        let fm = FileManager.default
        guard fm.fileExists(atPath: location.url.path) else { throw FilePitError.notFound("文件不存在") }
        if fm.fileExists(atPath: target.path), target.path != location.url.path {
            throw FilePitError.conflict("目标名称已存在")
        }
        try fm.moveItem(at: location.url, to: target)
        invalidate(parent)
        let parentComponents = location.relative.split(separator: "/").dropLast().map(String.init)
        let newVirtual = "/" + ([location.rootID] + parentComponents + [cleanName]).joined(separator: "/")
        return try entry(url: target, virtualPath: newVirtual, rootID: location.rootID, readOnly: location.readOnly)
    }

    @discardableResult
    func move(path: String, destinationDirectory: String, role: PitHubRole, settings: PitHubSettings) throws -> FilePitEntry {
        let source = try resolveFS(path: path, role: role, settings: settings, write: true)
        guard !source.relative.isEmpty else { throw FilePitError.invalidOperation("不能移动挂载根目录") }
        let destination = try resolveFS(path: destinationDirectory, role: role, settings: settings, write: true)
        guard destination.rootID == source.rootID else {
            throw FilePitError.invalidOperation("暂不支持跨挂载根目录移动，请先下载再上传")
        }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: destination.url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FilePitError.notFound("目标目录不存在")
        }
        let name = source.url.lastPathComponent
        let target = destination.url.appendingPathComponent(name)
        guard !PitHubPathGuard.isSubpath(target, of: source.url) else {
            throw FilePitError.invalidOperation("不能把目录移动到它自身内部")
        }
        if fm.fileExists(atPath: target.path) {
            throw FilePitError.conflict("目标目录已存在同名文件")
        }
        try fm.moveItem(at: source.url, to: target)
        invalidate(source.url.deletingLastPathComponent())
        invalidate(destination.url)
        let newVirtual = destination.virtualPath + "/" + name
        return try entry(url: target, virtualPath: newVirtual, rootID: source.rootID, readOnly: source.readOnly)
    }

    // MARK: - 上传

    @discardableResult
    func saveUpload(sourceFile: URL?, data: Data, size: Int64, path: String, role: PitHubRole,
                    settings: PitHubSettings, overwrite: Bool = true) throws -> FilePitEntry {
        let location = try resolveFS(path: path, role: role, settings: settings, write: true)
        guard !location.relative.isEmpty else { throw FilePitError.invalidOperation("上传路径必须包含文件名") }

        let name = location.url.lastPathComponent
        let parent = location.url.deletingLastPathComponent()
        let fm = FileManager.default
        var parentIsDirectory: ObjCBool = false
        guard fm.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory), parentIsDirectory.boolValue else {
            throw FilePitError.notFound("上级目录不存在")
        }

        let maxBytes = Int64(max(1, settings.filePit.maxUploadMB)) * 1024 * 1024
        guard size <= maxBytes else {
            throw FilePitError.tooLarge("文件超过上传上限 \(settings.filePit.maxUploadMB) MB")
        }
        try validateExtension(name: name, settings: settings)

        if fm.fileExists(atPath: location.url.path) {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: location.url.path, isDirectory: &isDir)
            if isDir.boolValue { throw FilePitError.conflict("目标路径是一个文件夹") }
            if !overwrite { throw FilePitError.conflict("文件已存在") }
            try? fm.removeItem(at: location.url)
        }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("pithub-upload-\(UUID().uuidString).tmp")
        if let sourceFile {
            try? fm.removeItem(at: staging)
            try fm.copyItem(at: sourceFile, to: staging)
        } else {
            try data.write(to: staging, options: .atomic)
        }
        try? fm.removeItem(at: location.url)
        try fm.moveItem(at: staging, to: location.url)
        invalidate(parent)
        notifyUpload(name: name, size: size)

        return try entry(url: location.url, virtualPath: location.virtualPath, rootID: location.rootID,
                         readOnly: location.readOnly, displayName: name)
    }

    private func validateExtension(name: String, settings: PitHubSettings) throws {
        let ext = name.pathExtensionLowercased
        guard !ext.isEmpty else { return }
        let blocked = settings.filePit.blockedExtensions
        if blocked.contains(ext) {
            throw FilePitError.blockedExtension(ext)
        }
    }

    // MARK: - 分片上传

    func createUploadSession(path: String, size: Int64, role: PitHubRole,
                             settings: PitHubSettings) throws -> FilePitUploadSession {
        let location = try resolveFS(path: path, role: role, settings: settings, write: true)
        guard !location.relative.isEmpty else { throw FilePitError.invalidOperation("上传路径必须包含文件名") }
        let name = location.url.lastPathComponent
        try validateExtension(name: name, settings: settings)

        let maxBytes = Int64(max(1, settings.filePit.maxUploadMB)) * 1024 * 1024
        guard size >= 0, size <= maxBytes else {
            throw FilePitError.tooLarge("文件超过上传上限 \(settings.filePit.maxUploadMB) MB")
        }
        let parent = location.url.deletingLastPathComponent()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDir), isDir.boolValue else {
            throw FilePitError.notFound("上级目录不存在")
        }

        let chunkSize = Int64(max(1, settings.filePit.chunkMB)) * 1024 * 1024
        let totalChunks = size == 0 ? 0 : Int((size + chunkSize - 1) / chunkSize)
        let identifier = Self.randomToken(length: 20)
        let session = FilePitUploadSession(
            id: identifier,
            virtualPath: location.virtualPath,
            fileName: name,
            totalSize: size,
            chunkSize: chunkSize,
            totalChunks: totalChunks,
            received: [],
            createdAt: Date()
        )

        let sessionDir = uploadDirectory.appendingPathComponent(identifier, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        saveSession(session, directory: sessionDir)

        lock.lock()
        uploadSessions[identifier] = session
        lock.unlock()
        return session
    }

    func putChunk(uploadID: String, index: Int, sourceFile: URL?, data: Data, size: Int64,
                  role: PitHubRole, settings: PitHubSettings) throws -> FilePitUploadSession {
        lock.lock()
        defer { lock.unlock() }
        guard var session = uploadSessions[uploadID] else {
            throw FilePitError.notFound("上传会话不存在或已过期")
        }
        try resolveFS(path: session.virtualPath, role: role, settings: settings, write: true)

        guard index >= 0, index < session.totalChunks else {
            throw FilePitError.invalidOperation("分片序号越界")
        }
        let expected: Int64 = index == session.totalChunks - 1
            ? session.totalSize - Int64(index) * session.chunkSize
            : session.chunkSize
        guard size == expected else {
            throw FilePitError.invalidOperation("分片大小不正确，期望 \(expected) 字节，收到 \(size) 字节")
        }

        let sessionDir = uploadDirectory.appendingPathComponent(uploadID, isDirectory: true)
        try PitHubPaths.ensureDirectory(sessionDir)
        let partURL = sessionDir.appendingPathComponent("chunk-\(index).part")
        try? FileManager.default.removeItem(at: partURL)
        if let sourceFile {
            try FileManager.default.copyItem(at: sourceFile, to: partURL)
        } else {
            try data.write(to: partURL, options: .atomic)
        }

        if !session.received.contains(index) {
            session.received.append(index)
            session.received.sort()
        }
        saveSession(session, directory: sessionDir)
        uploadSessions[uploadID] = session
        return session
    }

    @discardableResult
    func completeUpload(uploadID: String, role: PitHubRole, settings: PitHubSettings) throws -> FilePitEntry {
        lock.lock()
        guard let session = uploadSessions[uploadID] else {
            lock.unlock()
            throw FilePitError.notFound("上传会话不存在或已过期")
        }
        let missing = session.missingChunks
        guard missing.isEmpty else {
            lock.unlock()
            throw FilePitError.conflict("还有 \(missing.count) 个分片未上传")
        }
        guard let location = try? resolveFS(path: session.virtualPath, role: role, settings: settings, write: true),
              !location.relative.isEmpty else {
            lock.unlock()
            throw FilePitError.invalidPath
        }
        let sessionDir = uploadDirectory.appendingPathComponent(uploadID, isDirectory: true)
        let assembled = sessionDir.appendingPathComponent("assembled.part")
        try? FileManager.default.removeItem(at: assembled)
        FileManager.default.createFile(atPath: assembled.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: assembled) else {
            lock.unlock()
            throw FilePitError.io("无法创建合并文件")
        }
        do {
            for index in 0..<session.totalChunks {
                let partURL = sessionDir.appendingPathComponent("chunk-\(index).part")
                guard let input = try? FileHandle(forReadingFrom: partURL) else {
                    throw FilePitError.io("分片 \(index) 丢失，无法合并")
                }
                while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                    try output.write(contentsOf: chunk)
                }
                try? input.close()
            }
            try output.close()
        } catch {
            try? output.close()
            lock.unlock()
            if let fileError = error as? FilePitError { throw fileError }
            throw FilePitError.io("合并分片失败：\(error.localizedDescription)")
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: assembled.path)
        let assembledSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard assembledSize == session.totalSize else {
            lock.unlock()
            throw FilePitError.io("合并后的文件大小不一致")
        }

        let parent = location.url.deletingLastPathComponent()
        do {
            try? FileManager.default.removeItem(at: location.url)
            try FileManager.default.moveItem(at: assembled, to: location.url)
            try? FileManager.default.removeItem(at: sessionDir)
        } catch {
            lock.unlock()
            throw FilePitError.io("保存文件失败：\(error.localizedDescription)")
        }
        uploadSessions.removeValue(forKey: uploadID)
        lock.unlock()

        invalidate(parent)
        notifyUpload(name: session.fileName, size: session.totalSize)
        return try entry(url: location.url, virtualPath: location.virtualPath, rootID: location.rootID,
                         readOnly: location.readOnly, displayName: session.fileName)
    }

    func uploadStatus(id: String) -> FilePitUploadSession? {
        lock.lock()
        defer { lock.unlock() }
        return uploadSessions[id]
    }

    func cancelUpload(id: String) {
        lock.lock()
        uploadSessions.removeValue(forKey: id)
        lock.unlock()
        let dir = uploadDirectory.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    private func loadUploadSessions() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: uploadDirectory, includingPropertiesForKeys: nil) else { return }
        for dir in dirs {
            let metaURL = dir.appendingPathComponent("session.json")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let data = try? Data(contentsOf: metaURL),
                  let session = try? decoder.decode(FilePitUploadSession.self, from: data) else { continue }
            uploadSessions[session.id] = session
        }
    }

    private func saveSession(_ session: FilePitUploadSession, directory: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(session) {
            try? data.write(to: directory.appendingPathComponent("session.json"), options: .atomic)
        }
    }

    private func cleanupStaleUploads() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: uploadDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for dir in dirs {
            let values = try? dir.resourceValues(forKeys: [.contentModificationDateKey])
            let date = values?.contentModificationDate ?? Date.distantPast
            if Date().timeIntervalSince(date) > 24 * 3600 {
                try? fm.removeItem(at: dir)
                uploadSessions.removeValue(forKey: dir.lastPathComponent)
            }
        }
    }

    // MARK: - 下载 / ZIP

    func downloadResponse(path: String, role: PitHubRole, settings: PitHubSettings,
                          inline: Bool, photoResource: PitHubPhotoResource,
                          completion: @escaping (HTTPResponse) -> Void) {
        let components = split(path)
        if components.first?.lowercased() == "photos" {
            guard components.count == 3,
                  let albumID = Self.decodePhotoToken(components[1]) else {
                completion(HTTPResponse.error(400, "相册文件路径无效"))
                return
            }
            let allowedAlbums = settings.photoNode.allowedAlbumIDs
            if !allowedAlbums.isEmpty && !allowedAlbums.contains(albumID) {
                completion(HTTPResponse.error(403, "该相册未开启共享"))
                return
            }
            exportPhotoFile(fileToken: components[2], settings: settings,
                            resource: photoResource, inline: inline, completion: completion)
            return
        }
        do {
            let location = try resolveFS(path: path, role: role, settings: settings, write: false)
            let fm = FileManager.default
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: location.url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw FilePitError.notFound("文件不存在")
            }
            let name = location.url.lastPathComponent
            var response = HTTPResponse.file(
                url: location.url,
                contentType: PitHubMIME.type(for: name),
                downloadName: name,
                inline: inline,
                supportsRange: true,
                action: "download"
            )
            if !inline {
                response.headers["Cache-Control"] = "no-store"
            }
            completion(response)
        } catch let error as FilePitError {
            completion(error.response())
        } catch {
            completion(HTTPResponse.error(500, error.localizedDescription))
        }
    }

    private func exportPhotoFile(fileToken: String, settings: PitHubSettings,
                                 resource: PitHubPhotoResource,
                                 inline: Bool, completion: @escaping (HTTPResponse) -> Void) {
        guard let assetID = Self.decodePhotoToken(Self.stripExtension(fileToken)) else {
            completion(HTTPResponse.error(404, "照片不存在"))
            return
        }
        guard let host else {
            completion(HTTPResponse.error(503, "服务未就绪"))
            return
        }
        let library = host.photoLibrary
        guard library.isAuthorized else {
            completion(HTTPResponse.error(403, "相册权限未开启"))
            return
        }
        if let allowed = library.allowedAssetIdentifiers(allowedAlbumIDs: settings.photoNode.allowedAlbumIDs),
           !allowed.contains(assetID) {
            completion(HTTPResponse.error(403, "该照片所在相册未开启共享"))
            return
        }
        guard let info = library.assetInfo(identifier: assetID) else {
            completion(HTTPResponse.error(404, "照片不存在"))
            return
        }

        let exportName: String
        if resource == .pairedVideo {
            exportName = "\(assetID.replacingOccurrences(of: "/", with: "_")).mov"
        } else {
            exportName = info.filename
        }
        let destination = exportDirectory.appendingPathComponent(UUID().uuidString + "-" + exportName.sanitizedFileName)
        try? PitHubPaths.ensureDirectory(exportDirectory)

        library.export(identifier: assetID, resource: resource, to: destination) { result in
            switch result {
            case .failure(let error):
                completion(HTTPResponse.error(404, "相册导出失败：\(error.localizedDescription)"))
            case .success(let filename):
                let contentType = PitHubMIME.type(for: filename)
                var response = HTTPResponse.file(
                    url: destination,
                    contentType: resource == .pairedVideo ? "video/quicktime" : contentType,
                    downloadName: filename,
                    inline: inline,
                    supportsRange: true,
                    cleanup: true,
                    action: "photo-download"
                )
                response.headers["Cache-Control"] = "no-store"
                completion(response)
            }
        }
    }

    /// 浏览器在线预览图片：HEIC/HEIF 统一转成 JPEG；相册文件走 PhotoKit 缩略图。
    func previewResponse(path: String, role: PitHubRole, settings: PitHubSettings,
                         maxPixel: Int, completion: @escaping (HTTPResponse) -> Void) {
        let pixel = max(64, min(2048, maxPixel))
        let components = split(path)

        if components.first?.lowercased() == "photos" {
            guard settings.filePit.allowPhotoMount else {
                completion(HTTPResponse.error(404, "相册挂载未开启"))
                return
            }
            guard components.count == 3,
                  let albumID = Self.decodePhotoToken(components[1]),
                  let assetID = Self.decodePhotoToken(Self.stripExtension(components[2])) else {
                completion(HTTPResponse.error(400, "相册预览路径无效"))
                return
            }
            let allowedAlbums = settings.photoNode.allowedAlbumIDs
            if !allowedAlbums.isEmpty && !allowedAlbums.contains(albumID) {
                completion(HTTPResponse.error(403, "该相册未开启共享"))
                return
            }
            guard let host else {
                completion(HTTPResponse.error(503, "服务未就绪"))
                return
            }
            let library = host.photoLibrary
            guard library.isAuthorized else {
                completion(HTTPResponse.error(403, "相册权限未开启"))
                return
            }
            if let allowed = library.allowedAssetIdentifiers(allowedAlbumIDs: allowedAlbums),
               !allowed.contains(assetID) {
                completion(HTTPResponse.error(403, "该照片所在相册未开启共享"))
                return
            }
            guard let info = library.assetInfo(identifier: assetID) else {
                completion(HTTPResponse.error(404, "照片不存在"))
                return
            }
            let cacheKey = "photo-preview:\(assetID):\(pixel):\(Int(info.modifiedAt.timeIntervalSince1970))"
            if let cached = host.thumbnailCache.data(forKey: cacheKey) {
                completion(jpegResponse(cached, maxAge: 3600))
                return
            }
            library.thumbnailData(identifier: assetID, maxPixel: CGFloat(pixel), quality: 0.82) { data in
                guard let data else {
                    completion(HTTPResponse.error(415, "无法生成相册预览"))
                    return
                }
                _ = host.thumbnailCache.store(data: data, forKey: cacheKey)
                completion(self.jpegResponse(data, maxAge: 3600))
            }
            return
        }

        do {
            let location = try resolveFS(path: path, role: role, settings: settings, write: false)
            let fm = FileManager.default
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: location.url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw FilePitError.notFound("文件不存在")
            }
            let name = location.url.lastPathComponent
            let ext = name.pathExtensionLowercased
            if ext == "svg" {
                var response = HTTPResponse.file(
                    url: location.url,
                    contentType: "image/svg+xml",
                    downloadName: name,
                    inline: true,
                    supportsRange: true,
                    action: "file-preview"
                )
                response.headers["Cache-Control"] = "private, max-age=3600"
                completion(response)
                return
            }
            guard PitHubMIME.isImage(name) else {
                throw FilePitError.invalidOperation("该文件不是图片")
            }
            let attributes = try? fm.attributesOfItem(atPath: location.url.path)
            let mtime = (attributes?[.modificationDate] as? Date) ?? Date.distantPast
            let cacheKey = "file-preview:\(location.url.path):\(mtime.timeIntervalSince1970):\(pixel)"
            if let host, let cached = host.thumbnailCache.data(forKey: cacheKey) {
                completion(jpegResponse(cached, maxAge: 3600))
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let data = PitHubImagePreview.jpegData(from: location.url, maxPixel: pixel) else {
                    completion(HTTPResponse.error(415, "该图片格式无法在浏览器中预览，请下载查看"))
                    return
                }
                if let host = self?.host {
                    _ = host.thumbnailCache.store(data: data, forKey: cacheKey)
                }
                completion(self?.jpegResponse(data, maxAge: 3600)
                    ?? HTTPResponse.error(503, "服务未就绪"))
            }
        } catch let error as FilePitError {
            completion(error.response())
        } catch {
            completion(HTTPResponse.error(500, error.localizedDescription))
        }
    }

    private func jpegResponse(_ data: Data, maxAge: Int) -> HTTPResponse {
        var response = HTTPResponse(status: 200, body: .data(data), logAction: "file-preview")
        response.headers["Content-Type"] = "image/jpeg"
        response.headers["Cache-Control"] = "private, max-age=\(maxAge)"
        return response
    }

    func zipResponse(path: String, role: PitHubRole, settings: PitHubSettings,
                     completion: @escaping (HTTPResponse) -> Void) {
        guard settings.filePit.allowZipDownload else {
            completion(HTTPResponse.error(403, "ZIP 打包下载已关闭"))
            return
        }
        let components = split(path)
        guard components.first?.lowercased() != "photos" else {
            completion(HTTPResponse.error(400, "相册目录不支持 ZIP，请使用 PhotoNode 下载"))
            return
        }
        do {
            let location = try resolveFS(path: path, role: role, settings: settings, write: false)
            let fm = FileManager.default
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: location.url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw FilePitError.invalidOperation("只有文件夹支持 ZIP 打包")
            }
            let attributes = try? fm.attributesOfItem(atPath: location.url.path)
            let mtime = (attributes?[.modificationDate] as? Date) ?? Date()
            let cacheKey = "zip:\(location.virtualPath):\(mtime.timeIntervalSince1970)"
            if let cache = host?.cache, let cachedURL = cache.fileURL(forKey: cacheKey) {
                let response = zipFileResponse(url: cachedURL, name: location.url.lastPathComponent + ".zip")
                completion(response)
                return
            }

            let folderName = location.url.lastPathComponent
            let tempZip = FileManager.default.temporaryDirectory
                .appendingPathComponent("pithub-\(UUID().uuidString).zip")

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let host = self?.host else {
                    completion(HTTPResponse.error(503, "服务未就绪"))
                    return
                }
                do {
                    var entries: [PitHubZipEntry] = []
                    var totalSize: Int64 = 0
                    try Self.collectZipEntries(at: location.url, prefix: folderName + "/", entries: &entries, totalSize: &totalSize)
                    guard !entries.isEmpty else {
                        completion(HTTPResponse.error(404, "文件夹为空，无法打包"))
                        return
                    }
                    try PitHubZipWriter.write(entries: entries, to: tempZip)
                    try host.cache.store(fileAt: tempZip, forKey: cacheKey)
                    try? FileManager.default.removeItem(at: tempZip)
                    guard let cachedURL = host.cache.fileURL(forKey: cacheKey) else {
                        completion(HTTPResponse.error(500, "ZIP 缓存写入失败"))
                        return
                    }
                    completion(self?.zipFileResponse(url: cachedURL, name: folderName + ".zip")
                        ?? HTTPResponse.error(500, "ZIP 生成失败"))
                } catch {
                    try? FileManager.default.removeItem(at: tempZip)
                    completion(HTTPResponse.error(500, "ZIP 生成失败：\(error.localizedDescription)"))
                }
            }
        } catch let error as FilePitError {
            completion(error.response())
        } catch {
            completion(HTTPResponse.error(500, error.localizedDescription))
        }
    }

    private func zipFileResponse(url: URL, name: String) -> HTTPResponse {
        var response = HTTPResponse.file(
            url: url,
            contentType: "application/zip",
            downloadName: name,
            inline: false,
            supportsRange: true,
            action: "zip"
        )
        response.headers["Cache-Control"] = "no-store"
        return response
    }

    private static func collectZipEntries(at url: URL, prefix: String,
                                          entries: inout [PitHubZipEntry], totalSize: inout Int64) throws {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: []) else {
            return
        }
        for item in items {
            let name = item.lastPathComponent
            if name == ".DS_Store" { continue }
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                try collectZipEntries(at: item, prefix: prefix + name + "/", entries: &entries, totalSize: &totalSize)
            } else {
                let size = Int64(values?.fileSize ?? 0)
                totalSize += size
                guard totalSize < 4 * 1024 * 1024 * 1024 else { throw PitHubZipError.tooLarge }
                guard entries.count < 20000 else { throw PitHubZipError.tooLarge }
                entries.append(PitHubZipEntry(url: item, name: prefix + name))
            }
        }
    }

    // MARK: - 分享

    @discardableResult
    func createShare(path: String, role: PitHubRole, settings: PitHubSettings,
                     password: String, expiresMinutes: Int) throws -> FilePitShare {
        guard role >= .user else { throw FilePitError.forbidden("访客不能创建分享") }
        let components = split(path)
        guard components.first?.lowercased() != "photos" else {
            throw FilePitError.invalidOperation("相册文件请通过 PhotoNode 下载/分享")
        }
        let location = try resolveFS(path: path, role: role, settings: settings, write: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: location.url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw FilePitError.notFound("只能分享单个文件")
        }

        let minutes = max(1, min(10080, expiresMinutes))
        let token = Self.randomToken(length: 24)
        var salt = ""
        var hash = ""
        if !password.isEmpty {
            salt = PitHubPassword.makeSalt()
            hash = PitHubPassword.hash(password, salt: salt)
        }
        let share = FilePitShare(
            token: token,
            virtualPath: location.virtualPath,
            fileName: location.url.lastPathComponent,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(TimeInterval(minutes * 60)),
            passwordSalt: salt,
            passwordHash: hash,
            creatorRole: role.rawValue
        )

        lock.lock()
        cleanupExpiredSharesLocked()
        shares.append(share)
        persistSharesLocked()
        lock.unlock()
        return share
    }

    func listShares() -> [FilePitShare] {
        lock.lock()
        cleanupExpiredSharesLocked()
        let snapshot = shares.sorted { $0.createdAt > $1.createdAt }
        lock.unlock()
        return snapshot
    }

    func deleteShare(token: String) throws {
        lock.lock()
        let existed = shares.contains { $0.token == token }
        shares.removeAll { $0.token == token }
        persistSharesLocked()
        lock.unlock()
        if !existed { throw FilePitError.notFound("分享不存在") }
    }

    func shareResponse(token: String, request: HTTPRequest) -> HTTPResponse {
        lock.lock()
        cleanupExpiredSharesLocked()
        guard let share = shares.first(where: { $0.token == token }) else {
            lock.unlock()
            return HTTPResponse.error(404, "分享链接不存在或已过期")
        }
        lock.unlock()

        let cookieName = "pithub_share_\(token)"
        let isAuthorized = !share.isPasswordProtected || request.cookies[cookieName] == share.passwordHash

        if !isAuthorized {
            if request.method == "POST" {
                let form = Self.parseForm(request.bodyData(maxBytes: 64 * 1024) ?? Data())
                let password = form["password"] ?? ""
                guard PitHubPassword.verify(password, salt: share.passwordSalt, hash: share.passwordHash) else {
                    return passwordPage(share: share, error: "密码不正确")
                }
                let maxAge = max(60, Int(share.expiresAt.timeIntervalSinceNow))
                var response = HTTPResponse.redirect("/s/\(token)" + (form["download"] == "1" ? "?download=1" : ""))
                response.headers["Set-Cookie"] = "\(cookieName)=\(share.passwordHash); Path=/; Max-Age=\(maxAge); HttpOnly; SameSite=Lax"
                response.logAction = "share-unlock"
                return response
            }
            return passwordPage(share: share, error: nil)
        }

        let download = request.query["download"] == "1"
        guard let settings = host?.settingsSnapshot else {
            return HTTPResponse.error(503, "服务未就绪")
        }

        do {
            let location = try resolveFS(path: share.virtualPath, role: .admin, settings: settings, write: false)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: location.url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return HTTPResponse.error(404, "分享的文件已被删除")
            }
            var response = HTTPResponse.file(
                url: location.url,
                contentType: PitHubMIME.type(for: share.fileName),
                downloadName: share.fileName,
                inline: !download,
                supportsRange: true,
                action: "share-download"
            )
            response.headers["Cache-Control"] = "no-store"
            return response
        } catch let error as FilePitError {
            return error.response()
        } catch {
            return HTTPResponse.error(500, error.localizedDescription)
        }
    }

    private func passwordPage(share: FilePitShare, error: String?) -> HTTPResponse {
        let escapedName = share.fileName.htmlEscaped
        let errorBlock = error.map { "<p class=\"err\">\($0.htmlEscaped)</p>" } ?? ""
        let html = """
        <!DOCTYPE html>
        <html lang="zh-CN"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>PitHub 分享 · \(escapedName)</title>
        <style>
        :root{color-scheme:dark}
        body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
          background:radial-gradient(circle at 20% 0%,#12233b,#06080d 60%);color:#e8eefc;
          font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",sans-serif}
        .card{width:min(92vw,380px);padding:28px;border-radius:22px;background:rgba(255,255,255,.06);
          border:1px solid rgba(255,255,255,.12);backdrop-filter:blur(28px);box-shadow:0 24px 60px rgba(0,0,0,.4)}
        .logo{font-size:13px;letter-spacing:.24em;color:#7ea7ff;text-transform:uppercase}
        h1{font-size:20px;margin:10px 0 2px;font-weight:600}
        .file{color:#9aa8c2;font-size:13px;margin-bottom:22px;word-break:break-all}
        input{width:100%;box-sizing:border-box;padding:12px 14px;border-radius:12px;border:1px solid rgba(255,255,255,.16);
          background:rgba(255,255,255,.06);color:#e8eefc;font-size:15px;outline:none}
        input:focus{border-color:#5b8def}
        .row{display:flex;align-items:center;gap:8px;margin:14px 0 18px;color:#9aa8c2;font-size:13px}
        button{width:100%;padding:12px;border-radius:12px;border:0;background:#4f7fe8;color:#fff;font-size:15px;font-weight:600}
        .err{color:#ff8a8a;font-size:13px;margin:10px 0 0}
        .tip{color:#6d7a93;font-size:12px;margin-top:18px;line-height:1.6}
        </style></head><body>
        <div class="card">
          <div class="logo">PitHub · FilePit</div>
          <h1>受保护的分享</h1>
          <div class="file">\(escapedName)</div>
          \(errorBlock)
          <form method="post" action="">
            <input type="password" name="password" placeholder="输入分享密码" autofocus required>
            <div class="row"><label><input type="checkbox" name="download" value="1" style="width:auto"> 作为附件下载</label></div>
            <button type="submit">解锁并下载</button>
          </form>
          <div class="tip">此链接由 PitHub 生成，到期时间 \(PitHubFormat.fileDate(share.expiresAt))。文件不会被上传到任何第三方服务器。</div>
        </div></body></html>
        """
        var response = HTTPResponse.html(html)
        response.logAction = "share-password"
        return response
    }

    private func loadShares() {
        guard let data = try? Data(contentsOf: shareFileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        shares = (try? decoder.decode([FilePitShare].self, from: data)) ?? []
    }

    private func persistSharesLocked() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(shares) {
            try? PitHubPaths.ensureDirectory(shareFileURL.deletingLastPathComponent())
            try? data.write(to: shareFileURL, options: .atomic)
        }
    }

    private func cleanupExpiredSharesLocked() {
        let before = shares.count
        shares.removeAll { $0.isExpired }
        if shares.count != before { persistSharesLocked() }
    }

    private func cleanupExpiredShares() {
        lock.lock()
        cleanupExpiredSharesLocked()
        lock.unlock()
    }

    private func cleanupExports() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: exportDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for item in items {
            let values = try? item.resourceValues(forKeys: [.contentModificationDateKey])
            let date = values?.contentModificationDate ?? Date.distantPast
            if Date().timeIntervalSince(date) > 6 * 3600 {
                try? fm.removeItem(at: item)
            }
        }
    }

    // MARK: - 相册挂载

    private func listPhotos(components: [String], role: PitHubRole, settings: PitHubSettings) throws -> [FilePitEntry] {
        guard settings.filePit.allowPhotoMount else { throw FilePitError.notFound("相册挂载未开启") }
        guard let host, host.photoLibrary.isAuthorized else { throw FilePitError.noPhotoPermission }
        let library = host.photoLibrary

        if components.isEmpty {
            let albums = library.albums(allowedIDs: settings.photoNode.allowedAlbumIDs)
            return albums.map { album in
                FilePitEntry(
                    name: album.title,
                    path: "/photos/\(Self.encodePhotoToken(album.id))",
                    isDirectory: true,
                    kind: "album",
                    mime: "inode/directory",
                    isReadOnly: true,
                    rootID: "photos",
                    assetCount: album.count
                )
            }
        }

        guard components.count == 1, let albumID = Self.decodePhotoToken(components[0]) else {
            throw FilePitError.invalidPath
        }
        if !settings.photoNode.allowedAlbumIDs.isEmpty,
           albumID != "all",
           !settings.photoNode.allowedAlbumIDs.contains(albumID) {
            throw FilePitError.forbidden("该相册未开启共享")
        }

        let cacheKey = "photos:\(albumID):\(settings.photoNode.includeVideos):\(settings.photoNode.includeHiddenAssets):\(settings.photoNode.allowedAlbumIDs.joined(separator: ","))"
        lock.lock()
        if let cached = photoCache[cacheKey], Date().timeIntervalSince(cached.date) < 30 {
            let entries = cached.entries
            lock.unlock()
            return entries
        }
        lock.unlock()

        var assets: [PitHubPhotoAsset] = []
        var offset = 0
        let cap = 5000
        while assets.count < cap {
            let page = library.assets(
                albumID: albumID,
                allowedAlbumIDs: settings.photoNode.allowedAlbumIDs,
                includeVideos: settings.photoNode.includeVideos,
                includeHidden: settings.photoNode.includeHiddenAssets,
                year: nil,
                month: nil,
                offset: offset,
                limit: 500
            )
            if page.items.isEmpty { break }
            assets.append(contentsOf: page.items)
            offset += page.items.count
            if assets.count >= page.total { break }
        }

        let albumToken = Self.encodePhotoToken(albumID)
        let entries = assets.map { asset -> FilePitEntry in
            let ext = Self.photoExtension(for: asset)
            return FilePitEntry(
                name: asset.filename,
                path: "/photos/\(albumToken)/\(Self.encodePhotoToken(asset.id)).\(ext)",
                isDirectory: false,
                size: 0,
                modified: asset.createdAt.timeIntervalSince1970,
                kind: asset.mediaType,
                mime: asset.mimeType,
                isReadOnly: true,
                rootID: "photos",
                isLivePhoto: asset.isLivePhoto,
                duration: asset.duration
            )
        }
        lock.lock()
        if photoCache.count > 20 { photoCache.removeAll() }
        photoCache[cacheKey] = (Date(), entries)
        lock.unlock()
        return entries
    }

    private func photoStat(components: [String], role: PitHubRole, settings: PitHubSettings) throws -> FilePitEntry {
        guard settings.filePit.allowPhotoMount else { throw FilePitError.notFound("相册挂载未开启") }
        guard let host, host.photoLibrary.isAuthorized else { throw FilePitError.noPhotoPermission }
        if components.isEmpty {
            return FilePitEntry(name: "Photos", path: "/photos", isDirectory: true, kind: "folder",
                                mime: "inode/directory", isReadOnly: true, rootID: "photos")
        }
        guard let albumID = Self.decodePhotoToken(components[0]) else { throw FilePitError.invalidPath }
        if components.count == 1 {
            let albums = host.photoLibrary.albums(allowedIDs: settings.photoNode.allowedAlbumIDs)
            guard let album = albums.first(where: { $0.id == albumID }) else {
                throw FilePitError.notFound("相册不存在或未共享")
            }
            return FilePitEntry(name: album.title, path: "/photos/\(components[0])", isDirectory: true,
                                kind: "album", mime: "inode/directory", isReadOnly: true,
                                rootID: "photos", assetCount: album.count)
        }
        guard components.count == 2,
              let assetID = Self.decodePhotoToken(Self.stripExtension(components[1])),
              let info = host.photoLibrary.assetInfo(identifier: assetID) else {
            throw FilePitError.notFound("照片不存在")
        }
        let allowedAlbums = settings.photoNode.allowedAlbumIDs
        if !allowedAlbums.isEmpty && !allowedAlbums.contains(albumID) {
            throw FilePitError.forbidden("该相册未开启共享")
        }
        if let allowed = host.photoLibrary.allowedAssetIdentifiers(allowedAlbumIDs: allowedAlbums),
           !allowed.contains(assetID) {
            throw FilePitError.forbidden("该照片所在相册未开启共享")
        }
        return FilePitEntry(
            name: info.filename,
            path: "/photos/\(components[0])/\(components[1])",
            isDirectory: false,
            size: 0,
            modified: info.createdAt.timeIntervalSince1970,
            kind: info.mediaType,
            mime: info.mimeType,
            isReadOnly: true,
            rootID: "photos",
            isLivePhoto: info.isLivePhoto,
            duration: info.duration
        )
    }

    // MARK: - 工具

    private func invalidate(_ url: URL) {
        lock.lock()
        let pathPrefix = url.path + "#"
        let keysToRemove = listingCache.keys.filter { $0.hasPrefix(pathPrefix) }
        for key in keysToRemove {
            listingCache.removeValue(forKey: key)
        }
        lock.unlock()
    }

    private func notifyUpload(name: String, size: Int64) {
        guard let host, host.settingsSnapshot.notificationsEnabled else { return }
        host.notifier.notify(title: "上传完成", body: "\(name) · \(PitHubFormat.humanBytes(size))")
    }

    private static func randomToken(length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var result = ""
        for _ in 0..<length {
            result.append(alphabet[Int.random(in: 0..<alphabet.count)])
        }
        return result
    }

    static func encodePhotoToken(_ identifier: String) -> String {
        Data(identifier.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodePhotoToken(_ token: String) -> String? {
        var base64 = token
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func stripExtension(_ token: String) -> String {
        guard let dot = token.lastIndex(of: ".") else { return token }
        return String(token[..<dot])
    }

    private static func photoExtension(for asset: PitHubPhotoAsset) -> String {
        let ext = (asset.filename as NSString).pathExtension.lowercased()
        if !ext.isEmpty { return ext }
        return asset.mediaType == "video" ? "mov" : "jpg"
    }

    private static func parseForm(_ data: Data) -> [String: String] {
        let string = data.utf8String
        var result: [String: String] = [:]
        for pair in string.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(parts[0])
            let value = parts.count > 1
                ? (String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(parts[1]))
                : ""
            if !key.isEmpty { result[key] = value }
        }
        return result
    }
}
