import SwiftUI
import Foundation

/// Files 浏览的共享服务：连接、SFTP 操作、全局视图偏好、错误与默认目录。
/// 每一级目录的数据与选中态由各自的 DirectoryPage 持有，返回上层时天然保留状态。
/// 只依赖根 Core 的会话/SSH/钥匙串与 Files/Core 能力，不认识其他功能模块。
@MainActor
final class FileBrowserModel: ObservableObject {
    // MARK: - 连接
    @Published private(set) var isConnected = false
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    // MARK: - 全局视图偏好（系统「文件」App：各位置记住自己的视图，这里用全局简化）
    @Published var viewMode: FileViewMode = .list
    @Published var sortOrder: FileSortOrder = .name
    @Published var sortAscending = true
    @Published var showHiddenFiles = false

    private var client: SFTPClient?
    private var connectedServerID: UUID?

    var serverName: String { ServerSession.shared.currentServer?.name ?? "服务器文件" }

    /// 冷启动/单击 Tab 回根时的入口路径：未设默认目录进 "/"。
    var entryPath: String {
        guard let id = ServerSession.shared.currentServer?.id else { return "/" }
        return DefaultDirectoryStore.path(for: id) ?? "/"
    }

    // MARK: - 连接与冷启动

    func connectIfNeeded(force: Bool = false) async {
        guard let info = ServerSession.shared.currentServer else {
            clearSession()
            errorMessage = "请先在「设置 → 我的服务器」添加并连接一台服务器"
            return
        }
        if !force, connectedServerID == info.id, isConnected { return }

        clearSession()
        isLoading = true
        defer { isLoading = false }
        do {
            let secret = try KeychainStore.load(info.credentialKey)
            let credential: SSHAuthCredential
            switch info.authKind {
            case .password: credential = .password(secret)
            case .privateKey: credential = .privateKey(secret)
            }
            let ssh = try await SSHSession(
                host: info.host,
                port: info.port,
                username: info.username,
                credential: credential
            )
            self.client = try await SFTPClient.connect(session: ssh)
            self.connectedServerID = info.id
            self.isConnected = true
        } catch {
            clearSession()
            errorMessage = SSHSession.describe(error)
        }
    }

    private func clearSession() {
        client?.close()
        client = nil
        connectedServerID = nil
        isConnected = false
    }

    func reconnect() async { await connectIfNeeded(force: true) }

    // MARK: - 目录列表与排序

    func listDirectory(at path: String) async -> [RemoteFile] {
        guard let client else { return [] }
        do {
            let raw = try await client.listDirectory(path)
            return sortEntries(raw)
        } catch {
            errorMessage = SSHSession.describe(error)
            return []
        }
    }

    /// 目录优先，再按用户选择的字段排序；隐藏文件在此统一过滤。
    func sortEntries(_ input: [RemoteFile]) -> [RemoteFile] {
        var result = input
        if !showHiddenFiles {
            result = result.filter { !$0.name.hasPrefix(".") }
        }
        let ascending = sortAscending
        return result.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            switch sortOrder {
            case .name:
                let order = lhs.name.localizedStandardCompare(rhs.name)
                return ascending ? order == .orderedAscending : order == .orderedDescending
            case .kind:
                let l = FileKind(file: lhs).sortRank
                let r = FileKind(file: rhs).sortRank
                if l != r { return ascending ? l < r : l > r }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .date:
                let l = lhs.modified?.timeIntervalSince1970 ?? 0
                let r = rhs.modified?.timeIntervalSince1970 ?? 0
                if l != r { return ascending ? l < r : l > r }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .size:
                if lhs.size != rhs.size { return ascending ? lhs.size < rhs.size : lhs.size > rhs.size }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    // MARK: - 写操作（全部带 path，作用于当前所在目录，返回上层不受影响）

    func makeDirectory(at path: String, named name: String) async {
        guard let client else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await client.makeDirectory(client.joined(path, trimmed))
        } catch {
            errorMessage = SSHSession.describe(error)
        }
    }

    func rename(_ file: RemoteFile, in parent: String, to newName: String) async {
        guard let client else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await client.rename(from: file.path, to: client.joined(parent, trimmed))
        } catch {
            errorMessage = SSHSession.describe(error)
        }
    }

    func delete(_ files: [RemoteFile]) async {
        guard let client else { return }
        do {
            for file in files {
                if file.isDirectory {
                    try await client.removeDirectory(file.path)
                } else {
                    try await client.removeFile(file.path)
                }
            }
        } catch {
            errorMessage = SSHSession.describe(error)
        }
    }

    func transfer(_ files: [RemoteFile], operation: BatchOperation, to target: String) async {
        guard let client, !files.isEmpty else { return }
        let sources = files.map { shellQuote($0.path) }.joined(separator: " ")
        let command: String
        switch operation {
        case .move: command = "mv -f \(sources) \(shellQuote(target))"
        case .copy: command = "cp -R -f \(sources) \(shellQuote(target))"
        }
        do {
            let result = try await client.execute(command)
            if result.exitStatus != 0 {
                throw SFTPError.malformed(result.stderr.isEmpty ? "命令执行失败" : result.stderr)
            }
        } catch {
            errorMessage = SSHSession.describe(error)
        }
    }

    /// 压缩：返回生成的归档文件名，供视图在成功后刷新并定位。
    func compress(_ files: [RemoteFile], in path: String) async -> String? {
        guard let client, !files.isEmpty else { return nil }
        let names = files.map { shellQuote($0.name) }.joined(separator: " ")
        let archive = "archive-\(Int(Date().timeIntervalSince1970)).zip"
        let command = "cd \(shellQuote(path)) && zip -r -q \(shellQuote(archive)) \(names)"
        do {
            let result = try await client.execute(command)
            if result.exitStatus != 0 {
                throw SFTPError.malformed(result.stderr.isEmpty ? "压缩失败" : result.stderr)
            }
            return archive
        } catch {
            errorMessage = SSHSession.describe(error)
            return nil
        }
    }

    func setAsDefaultDirectory(_ path: String) {
        guard let id = ServerSession.shared.currentServer?.id else { return }
        DefaultDirectoryStore.set(path, for: id)
    }

    // MARK: - 预览与导出（QuickLook / 系统分享面板）

    /// 把远程文件下载到本地临时目录并返回 URL，保留扩展名以便系统识别类型。
    func localURL(for file: RemoteFile, purpose: String) async -> URL? {
        guard let client else { return nil }
        do {
            let data = try await client.readFile(file.path)
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("LonePanel-\(purpose)", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(file.name)
            try data.write(to: url)
            return url
        } catch {
            errorMessage = SSHSession.describe(error)
            return nil
        }
    }

    // MARK: - 危险路径（系统关键目录删除二次确认）

    static let dangerPaths: Set<String> = [
        "/etc", "/usr", "/bin", "/sbin", "/lib", "/lib64", "/boot",
        "/dev", "/proc", "/sys", "/var", "/root", "/System", "/Library", "/private"
    ]

    static func isDangerousPath(_ path: String) -> Bool {
        let clean = path.hasSuffix("/") ? String(path.dropLast()) : path
        if dangerPaths.contains(clean) { return true }
        return dangerPaths.contains { clean.hasPrefix($0 + "/") }
    }

    func dismissError() { errorMessage = nil }
}
