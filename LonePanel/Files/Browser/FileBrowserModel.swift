import SwiftUI
import Foundation

/// Files 浏览器的状态与操作。只依赖根 Core 的会话/SSH/钥匙串能力，
/// 以及 Files/Core 的 SFTP 与默认目录存储；不认识 Settings 等任何其他模块。
@MainActor
final class FileBrowserModel: ObservableObject {
    @Published private(set) var entries: [RemoteFile] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isConnected = false
    @Published var pathStack: [RemoteFile] = []
    @Published var searchText = ""
    @Published var errorMessage: String?
    @Published var previewURL: URL?
    @Published var pendingCreateFolder = false
    @Published var newFolderName = ""
    @Published var renaming: RemoteFile?
    @Published var renameText = ""
    @Published var deleting: RemoteFile?

    private var client: SFTPClient?
    private var currentPath = "/"
    private var connectedServerID: UUID?

    var serverName: String { ServerSession.shared.currentServer?.name ?? "未连接" }

    var currentDisplayName: String {
        pathStack.last?.name ?? "服务器文件"
    }

    var filteredEntries: [RemoteFile] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(keyword) }
    }

    // MARK: - 连接

    /// 依据当前连接建立 SFTP 会话；重复调用同一台服务器时复用。
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
            let sftp = try await SFTPClient.connect(session: ssh)
            self.client = sftp
            self.connectedServerID = info.id

            let home = try await sftp.canonicalize(".")
            let start = DefaultDirectoryStore.path(for: info.id) ?? home
            currentPath = start
            pathStack = []
            isConnected = true
            await loadCurrent()
        } catch {
            clearSession()
            errorMessage = SSHSession.describe(error)
        }
    }

    func disconnect() {
        clearSession()
    }

    private func clearSession() {
        client?.close()
        client = nil
        connectedServerID = nil
        isConnected = false
        entries = []
        pathStack = []
    }

    // MARK: - 浏览

    func loadCurrent() async {
        guard let client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await client.listDirectory(currentPath).sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        } catch {
            errorMessage = SSHSession.describe(error)
        }
    }

    func enter(_ file: RemoteFile) {
        guard file.isDirectory else { return }
        pathStack.append(file)
        currentPath = file.path
        Task { await loadCurrent() }
    }

    func goBack() {
        guard !pathStack.isEmpty else { return }
        pathStack.removeLast()
        currentPath = pathStack.last?.path ?? homePathFallback()
        Task { await loadCurrent() }
    }

    private func homePathFallback() -> String {
        guard let info = ServerSession.shared.currentServer,
              let saved = DefaultDirectoryStore.path(for: info.id) else { return "/" }
        return saved
    }

    // MARK: - 操作

    func setAsDefaultDirectory() {
        guard let info = ServerSession.shared.currentServer else { return }
        DefaultDirectoryStore.set(currentPath, for: info.id)
    }

    func createFolder() async {
        guard let client, !newFolderName.isEmpty else { return }
        let target = client.joined(currentPath, newFolderName.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            try await client.makeDirectory(target)
            newFolderName = ""
            await loadCurrent()
        } catch {
            errorMessage = SSHSession.describe(error)
        }
    }

    func confirmRename() async {
        guard let client, let file = renaming else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let target = client.joined(currentPath, trimmed)
        do {
            try await client.rename(from: file.path, to: target)
            renaming = nil
            await loadCurrent()
        } catch {
            errorMessage = SSHSession.describe(error)
        }
    }

    func confirmDelete() async {
        guard let client, let file = deleting else { return }
        do {
            if file.isDirectory {
                try await client.removeDirectory(file.path)
            } else {
                try await client.removeFile(file.path)
            }
            deleting = nil
            await loadCurrent()
        } catch {
            errorMessage = SSHSession.describe(error)
        }
    }

    /// 下载文件到临时目录，交给系统 Quick Look 原生预览。
    func preview(_ file: RemoteFile) async {
        guard let client, !file.isDirectory else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await client.readFile(file.path)
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathComponent(file.name)
            try FileManager.default.createDirectory(at: temp.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: temp)
            previewURL = temp
        } catch {
            errorMessage = SSHSession.describe(error)
        }
    }
}
