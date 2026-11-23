import SwiftUI
import Foundation

/// Files 浏览的共享服务：连接、SFTP 操作、全局视图偏好、错误与默认目录。
/// 每一级目录的数据与选中态由各自的 DirectoryPage 持有，返回上层时天然保留状态。
/// 只依赖根 Core 的会话/SSH/钥匙串与 Files/Core 能力，不认识其他功能模块。
@MainActor
final class FileBrowserModel: ObservableObject {
    /// 全局唯一实例：导航栈与连接状态跨 Tab 切换存活，
    /// 避免离开文件页再回来时因视图重建而回到默认目录。
    static let shared = FileBrowserModel()

    // MARK: - 导航（跨 Tab 保留）

    /// 导航栈：根页 "/" 不进栈，元素是逐级 push 的目录节点。
    /// 放在单例 model 中，切换 Tab 不丢失，停留在离开前的目录。
    @Published var navPath: [FileNode] = []
    /// 是否已完成首次导航初始化：冷启动建一次默认目录链，切回 Tab 不再重置。
    private(set) var navigationInitialized = false

    // MARK: - 搜索（全局一份，供导航栈统一渲染，各级目录页共享过滤）
    /// 搜索关键词：所有目录页用同一个词过滤各自条目。
    @Published var searchText = ""
    /// 是否处于搜索态：各级工具栏放大镜置 true，导航栈据此聚焦/收起。
    @Published var isSearching = false

    // MARK: - 连接
    @Published private(set) var isConnected = false
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    /// 最近一次连接是否失败（区分「正在连接」与「连接失败」，供加载态/重试态分流）。
    @Published private(set) var connectionFailed = false
    /// 每次成功（重）连接自增，供各目录页监听后刷新列表。
    @Published private(set) var refreshToken = 0
    /// 回前台后的静默重连进行中：界面保持快照，仅由顶栏下进度条提示。
    @Published private(set) var isBackgroundReconnecting = false
    /// 设置里是否已配置并选中服务器。
    var hasConfiguredServer: Bool { ServerSession.shared.currentServer != nil }

    // MARK: - 全局视图偏好（所有设置项按全局记忆，冷启动自动恢复）
    @Published var viewMode: FileViewMode = FilePreferencesStore.viewMode {
        didSet { FilePreferencesStore.viewMode = viewMode }
    }
    @Published var sortOrder: FileSortOrder = FilePreferencesStore.sortOrder {
        didSet { FilePreferencesStore.sortOrder = sortOrder }
    }
    @Published var sortAscending = FilePreferencesStore.sortAscending {
        didSet { FilePreferencesStore.sortAscending = sortAscending }
    }
    @Published var showHiddenFiles = FilePreferencesStore.showHiddenFiles {
        didSet { FilePreferencesStore.showHiddenFiles = showHiddenFiles }
    }

    /// 正在下载的文件路径 → 进度(0...1)。用于列表行内显示原生进度条。
    @Published var transferProgress: [String: Double] = [:]

    /// 批量操作（粘贴/移动/复制多个文件）的整体进度，nil 表示无进行中的批处理。
    @Published var batchProgress: BatchProgress?

    private var client: SFTPClient?
    private var connectedServerID: UUID?

    var serverName: String { ServerSession.shared.currentServer?.name ?? "服务器文件" }

    /// 冷启动/单击 Tab 回根时的入口路径：未设默认目录进 "/"。
    var entryPath: String {
        guard let id = ServerSession.shared.currentServer?.id else { return "/" }
        return DefaultDirectoryStore.path(for: id) ?? "/"
    }

    // MARK: - 导航栈管理

    /// 冷启动首次连接成功后，把导航栈展开到默认目录的每一级祖先（根 "/" 不进栈）。
    /// 只执行一次；此后切 Tab / 切回前台都不再改动导航栈，保留用户所处目录。
    func initializeNavigationIfNeeded() {
        guard !navigationInitialized else { return }
        navigationInitialized = true
        navPath = Self.pathChain(for: entryPath)
    }

    /// 显式回根：单击当前文件 Tab / 切换服务器时调用，重置到默认目录入口。
    /// 同时标记已初始化，避免之后切回 Tab 时 .task 再次用默认目录覆盖用户所在位置。
    func resetNavigationToEntry() {
        navigationInitialized = true
        navPath = Self.pathChain(for: entryPath)
    }

    /// 把默认目录绝对路径拆成从 "/home" 起的逐级节点（不含根 "/"）。
    /// 例如 "/home/www" → [("/home","home"), ("/home/www","www")]；"/" → []。
    static func pathChain(for path: String) -> [FileNode] {
        let clean = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard !clean.isEmpty, clean != "/" else { return [] }
        var result: [FileNode] = []
        var accumulated = ""
        for part in clean.split(separator: "/") {
            accumulated += "/" + part
            result.append(FileNode(path: accumulated, title: String(part)))
        }
        return result
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
        connectionFailed = false
        errorMessage = nil
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
            self.refreshToken &+= 1
        } catch {
            clearSession()
            connectionFailed = true
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

    /// 回前台静默重连：不调用 clearSession、不改动 isConnected，
    /// 因此界面保留切出去时的快照，不会全屏切到「正在连接服务器」。
    /// 新连接成功后原子替换 client 并递增 refreshToken 触发各目录页刷新列表。
    func reconnectSilently() async {
        guard let info = ServerSession.shared.currentServer, isConnected else { return }
        isBackgroundReconnecting = true
        defer { isBackgroundReconnecting = false }
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
            let newClient = try await SFTPClient.connect(session: ssh)
            // 成功后再替换：整个过程中 isConnected 保持 true，界面不闪断。
            client?.close()
            self.client = newClient
            self.connectedServerID = info.id
            self.refreshToken &+= 1
        } catch {
            // 静默重连失败：保留快照界面不闪断，但明确弹窗告知连接失败，
            // 让用户知道当前会话可能已不可用、可手动重新连接。
            errorMessage = "服务器连接失败：\(SSHSession.describe(error))"
        }
    }

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

    /// 校验名称：不能为空、不能含 "/" 或 null，避免生成异常路径。
    private func validName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains("/") && !trimmed.contains("\0") else {
            errorMessage = "名称不能包含「/」等非法字符"
            return nil
        }
        return trimmed
    }

    func makeDirectory(at path: String, named name: String) async {
        guard let client, let trimmed = validName(name) else { return }
        do {
            try await client.makeDirectory(client.joined(path, trimmed))
        } catch {
            errorMessage = SSHSession.describe(error)
        }
    }

    func rename(_ file: RemoteFile, in parent: String, to newName: String) async {
        guard let client, let trimmed = validName(newName) else { return }
        do {
            try await client.rename(from: file.path, to: client.joined(parent, trimmed))
        } catch {
            errorMessage = SSHSession.describe(error)
        }
    }

    /// 删除：优先走 SSH `rm -rf`，一条命令删掉全部（含非空目录），
    /// 规避 SFTP RMDIR 要求目录为空、且长请求遇后台重连易失败的问题。
    /// 服务端禁用 exec 时自动回退纯 SFTP 递归删除。
    func delete(_ files: [RemoteFile]) async {
        guard let client, !files.isEmpty else { return }
        do {
            let script = "rm -rf -- " + files.map { shellQuote($0.path) }.joined(separator: " ")
            let result = try await client.execute(script)
            if result.exitStatus == 0 {
                refreshToken &+= 1
                return
            }
            let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            errorMessage = reason.isEmpty ? "删除失败：服务器拒绝了操作" : "删除失败：\(reason)"
        } catch {
            // exec 通道不可用（服务端禁用命令执行）：回退纯 SFTP 递归删除。
            do {
                for file in files { try await deleteRecursive(client, file) }
                refreshToken &+= 1
            } catch {
                errorMessage = SSHSession.describe(error)
            }
        }
    }

    /// 纯 SFTP 递归删除：目录先删子项再删自身；软链按文件删，避免跟随。
    private func deleteRecursive(_ client: SFTPClient, _ file: RemoteFile) async throws {
        if file.isSymlink {
            try await client.removeFile(file.path)
            return
        }
        if file.isDirectory {
            for child in try await client.listDirectory(file.path) {
                try await deleteRecursive(client, child)
            }
            try await client.removeDirectory(file.path)
        } else {
            try await client.removeFile(file.path)
        }
    }

    /// 移动/复制：先走纯 SFTP（不依赖 exec，兼容禁用命令执行的服务器）；
    /// 若 SFTP 原语失败，再回退 SSH mv/cp -R，提高跨设备、占名等场景的成功率。
    /// 全程发布整体进度（已完成项/总项数），避免多文件或大文件夹粘贴时界面毫无变化。
    func transfer(_ files: [RemoteFile], operation: BatchOperation, to target: String) async {
        guard let client, !files.isEmpty else { return }
        let title = operation == .copy ? "正在复制" : "正在移动"
        batchProgress = BatchProgress(title: title, completed: 0, total: files.count,
                                      detail: files.first?.name ?? "", transferredBytes: 0, totalBytes: 0)
        defer { batchProgress = nil }

        do {
            for (index, file) in files.enumerated() {
                // 单文件复制有准确总字节 → 字节进度条；目录/移动没有可靠总量 → 走项数进度。
                let fileTotalBytes: Int64 = (operation == .copy && !file.isDirectory) ? file.size : 0
                batchProgress = BatchProgress(title: title, completed: index, total: files.count,
                                              detail: file.name, transferredBytes: 0,
                                              totalBytes: fileTotalBytes)
                switch operation {
                case .move:
                    try await client.move(file, toDirectory: target)
                case .copy:
                    try await client.copy(file, toDirectory: target) { copied in
                        Task { @MainActor [weak self] in
                            self?.batchProgress = BatchProgress(
                                title: title, completed: index, total: files.count,
                                detail: file.name, transferredBytes: copied,
                                totalBytes: fileTotalBytes
                            )
                        }
                    }
                }
            }
            batchProgress = BatchProgress(title: title, completed: files.count, total: files.count,
                                          detail: "完成", transferredBytes: 0, totalBytes: 0)
            return
        } catch {
            // 纯 SFTP 失败，继续尝试 SSH 命令回退（单条命令无法细分，显示不确定进度）。
            batchProgress = BatchProgress(title: "\(title)（服务器命令）", completed: 0,
                                          total: 0, detail: files.first?.name ?? "",
                                          transferredBytes: 0, totalBytes: 0)
        }
        let sources = files.map { shellQuote($0.path) }.joined(separator: " ")
        let directory = target.hasSuffix("/") ? target : target + "/"
        let command: String
        switch operation {
        case .move: command = "mv -f -- \(sources) \(shellQuote(directory))"
        case .copy: command = "cp -Rf -- \(sources) \(shellQuote(directory))"
        }
        do {
            let result = try await client.execute(command)
            if result.exitStatus != 0 {
                let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                errorMessage = reason.isEmpty
                    ? "\(operation.rawValue)失败：服务器拒绝了操作"
                    : "\(operation.rawValue)失败：\(reason)"
            }
        } catch {
            errorMessage = SSHSession.describe(error)
        }
    }

    /// 新建空文件：SFTP 以 creat|trunc|write 打开后即关闭，得到一个 0 字节文件。
    func makeFile(at path: String, named name: String) async {
        guard let client, let trimmed = validName(name) else { return }
        do {
            try await client.writeFile(client.joined(path, trimmed), data: Data())
        } catch {
            errorMessage = SSHSession.describe(error)
        }
    }

    // MARK: - 拷贝剪贴板（跨目录：在 A 目录拷贝，进入 B 目录粘贴）

    /// 拷入剪贴板的源文件（均为绝对路径，跨目录有效）。由模型持有，所有层级页面共享。
    @Published private(set) var clipboard: [RemoteFile] = []

    func copyToClipboard(_ files: [RemoteFile]) {
        guard !files.isEmpty else { return }
        clipboard = files
    }

    func clearClipboard() { clipboard = [] }

    /// 把剪贴板内容复制到目标目录。粘贴后保留剪贴板，可连续粘贴。
    /// 目标与某个源项同名同目录时会覆盖自身造成数据损坏，这里提前拦截并提示。
    func pasteClipboard(into target: String) async {
        guard !clipboard.isEmpty else { return }
        let normalizedTarget = (target as NSString).standardizingPath
        for file in clipboard {
            let sourceParent = (file.path as NSString).deletingLastPathComponent
            if (sourceParent as NSString).standardizingPath == normalizedTarget {
                errorMessage = "「\(file.name)」已在当前目录，无法粘贴到原位置。请先移动到其他目录。"
                return
            }
        }
        await transfer(clipboard, operation: .copy, to: target)
    }

    func setAsDefaultDirectory(_ path: String) {
        guard let id = ServerSession.shared.currentServer?.id else { return }
        DefaultDirectoryStore.set(path, for: id)
    }

    // MARK: - 大小格式化（统一处理 0 字节，避免 ByteCountFormatter 输出 "Zero KB"）

    /// 人类可读的大小文案。0 字节统一显示 "0 KB"，不使用系统默认的 "Zero KB"。
    static func sizeText(_ bytes: Int64) -> String {
        if bytes == 0 { return "0 KB" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - 文件夹真实统计（SSH du/find 命令，SFTP STAT 的目录 size 不可信）

    /// 用远端 shell 命令统计文件夹的真实磁盘占用、文件数、子目录数。
    /// 一条命令合并 du + 两次 find，降低往返；解析失败返回 nil，让界面显示「未知」。
    func folderStats(for file: RemoteFile) async -> FolderStats? {
        guard let client, file.isDirectory else { return nil }
        let path = shellQuote(file.path)
        // du -sk 输出「KB<TAB>路径」；find 统计不含目录自身，故子目录数 -1。
        let script = "bytes=$(du -sk -- \(path) 2>/dev/null | awk '{print $1}'); "
            + "files=$(find \(path) -type f 2>/dev/null | wc -l); "
            + "dirs=$(find \(path) -type d 2>/dev/null | wc -l); "
            + "echo \"${bytes:-0}|${files:-0}|$(( ${dirs:-1} - 1 ))\""
        do {
            let result = try await client.execute(script)
            guard result.exitStatus == 0 else { return nil }
            let parts = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 3,
                  let kb = Int64(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let files = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let dirs = Int(parts[2].trimmingCharacters(in: .whitespacesAndNewlines))
            else { return nil }
            return FolderStats(sizeBytes: kb * 1024, fileCount: files, directoryCount: max(0, dirs))
        } catch {
            return nil
        }
    }

    // MARK: - 上传（本地文件 → 当前目录）

    /// 把系统文件选择器给出的本地文件逐个上传到目标目录，复用批量进度 HUD。
    /// 每个文件先读取 Data 再分块写回；失败只提示当前文件，不中断其余上传。
    func upload(files urls: [URL], to directory: String) async {
        guard let client, !urls.isEmpty else { return }
        let title = "正在上传"
        batchProgress = BatchProgress(title: title, completed: 0, total: urls.count,
                                      detail: urls.first?.lastPathComponent ?? "",
                                      transferredBytes: 0, totalBytes: 0)
        defer { batchProgress = nil }

        for (index, url) in urls.enumerated() {
            let name = url.lastPathComponent
            batchProgress = BatchProgress(title: title, completed: index, total: urls.count,
                                          detail: name, transferredBytes: 0, totalBytes: 0)
            let reached = url.startAccessingSecurityScopedResource()
            defer { if reached { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let totalBytes = Int64(data.count)
                try await client.writeFile(client.joined(directory, name), data: data) { written in
                    Task { @MainActor [weak self] in
                        self?.batchProgress = BatchProgress(
                            title: title, completed: index, total: urls.count,
                            detail: name, transferredBytes: written, totalBytes: totalBytes
                        )
                    }
                }
            } catch {
                errorMessage = "上传「\(name)」失败：\(error.localizedDescription)"
            }
        }
        batchProgress = BatchProgress(title: title, completed: urls.count, total: urls.count,
                                      detail: "完成", transferredBytes: 0, totalBytes: 0)
    }

    // MARK: - 预览与导出（QuickLook / 系统分享面板）

    /// 把远程文件下载到本地临时目录并返回 URL，保留扩展名以便系统识别类型。
    func localURL(for file: RemoteFile, purpose: String) async -> URL? {
        guard let client else { return nil }
        transferProgress[file.path] = 0
        defer { transferProgress[file.path] = nil }
        do {
            let data = try await client.readFile(file.path, expectedSize: file.size) { [weak self] progress in
                Task { @MainActor in
                    guard let self else { return }
                    self.transferProgress[file.path] = progress
                }
            }
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
