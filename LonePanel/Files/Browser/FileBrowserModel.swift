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
    /// 点当前「文件」Tab 后的待恢复意图：iOS 26 会把导航栈系统级 pop 到根，
    /// 需要在 pop 之后把默认目录链设回。已在 FileBrowserView 中订阅（走本单例，必然触发）。
    @Published var pendingEntryRestore = false
    /// 恢复意图代次：避免上一次点击的兜底定时器误伤后一次点击。
    private var entryRestoreGeneration = 0

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
    /// 正在通过系统文件选择器上传：选择期间 App 会短暂进后台，
    /// 必须抑制回前台的静默重连，否则新连接替换并 close 掉正在上传的 client。
    @Published private(set) var isFileOperationActive = false
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

    /// 切到新服务器时回默认目录入口。
    /// 同时标记已初始化，避免之后切回 Tab 时 .task 再次用默认目录覆盖用户所在位置。
    func resetNavigationToEntry() {
        navigationInitialized = true
        cancelEntryRestore()
        let target = Self.pathChain(for: entryPath)
        guard navPath != target else { return }
        navPath = target
        // 重置后同步关闭可能残留的搜索/多选态（单例全局态），
        // 避免回到默认目录后工具栏仍停留在上一次的异常状态。
        searchText = ""
        isSearching = false
    }

    // MARK: - 再次点击当前文件 Tab：回默认目录（方案二）

    /// ContentView 拦截到「再次点击当前已选中 Tab」时调用。
    /// iOS 26 的 TabView 在点击当前 Tab 时会把嵌套 NavigationStack 系统级 pop 到根，
    /// 且该 pop 与本调用几乎同时、无法直接取消。策略是记录恢复意图，
    /// 并针对三种时序分别兜底：pop 已发生 / pop 稍后发生 / 系统不 pop。
    /// 目标目录每次都从 DefaultDirectoryStore 现读（entryPath）。
    func handleCurrentTabReselected() {
        let target = Self.pathChain(for: entryPath)
        entryRestoreGeneration += 1
        let generation = entryRestoreGeneration
        pendingEntryRestore = true

        // 情况 A：系统已经把导航栈 pop 空（或本就在根）→ 立即设回默认目录。
        if navPath.isEmpty {
            applyEntryRestore(target, generation: generation)
            return
        }

        // 情况 B/C：交给视图层 .onChange(navPath) 在检测到 pop 到空时消费；
        // 若系统根本不 pop，则用兜底定时器主动恢复。
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000) // 0.4s，覆盖系统 pop 动画窗口
            guard let self, self.pendingEntryRestore,
                  self.entryRestoreGeneration == generation else { return }
            self.applyEntryRestore(target, generation: generation)
        }
    }

    /// 视图层 .onChange(navPath) 检测到导航栈被 pop 到空时调用：立即设回默认目录。
    func consumeEntryRestoreIfPopped() {
        guard pendingEntryRestore, navPath.isEmpty else { return }
        applyEntryRestore(Self.pathChain(for: entryPath), generation: entryRestoreGeneration)
    }

    /// 用户在此意图待处理期间主动导航进了子目录 → 放弃恢复，别打断操作。
    func cancelEntryRestoreOnUserNavigation() {
        guard pendingEntryRestore else { return }
        cancelEntryRestore()
    }

    private func applyEntryRestore(_ target: [FileNode], generation: Int) {
        guard entryRestoreGeneration == generation else { return }
        cancelEntryRestore()
        guard navPath != target else { return }
        navPath = target
        searchText = ""
        isSearching = false
    }

    private func cancelEntryRestore() {
        pendingEntryRestore = false
        entryRestoreGeneration += 1
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

    /// 文件选择器打开/上传开始时调用，抑制回前台静默重连。
    func beginFileOperation() { isFileOperationActive = true }
    /// 文件操作结束时调用，恢复静默重连。
    func endFileOperation() { isFileOperationActive = false }

    /// 回前台静默重连：不调用 clearSession、不改动 isConnected，
    /// 因此界面保留切出去时的快照，不会全屏切到「正在连接服务器」。
    /// 新连接成功后原子替换 client 并递增 refreshToken 触发各目录页刷新列表。
    func reconnectSilently() async {
        // 上传进行中（含系统文件选择器打开期间）不重连：
        // 否则新连接会 close 掉正在写入的 client，导致上传静默失败。
        guard !isFileOperationActive else { return }
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

    /// 系统文件选择器状态放在单例里，由导航栈顶层统一承载 picker：
    /// 若挂在会被 push/pop 重建的目录页上，选择完成后的 completion 可能丢失，
    /// 表现为「选完文件点确认没有任何反应」。
    @Published var isUploadPickerPresented = false
    /// 上传目标目录：点菜单时记录当前页路径，completion 里读取，避免捕获已销毁的页面。
    @Published var uploadTargetDirectory = "/"

    /// 把系统文件选择器给出的本地文件逐个上传到目标目录，复用批量进度 HUD。
    /// 每个文件先读取 Data 再分块写回；失败只提示当前文件，不中断其余上传。
    func upload(files urls: [URL], to directory: String) async {
        guard !urls.isEmpty else { return }
        // 标记上传期：抑制回前台静默重连，避免 client 被替换导致写入中断。
        isFileOperationActive = true
        defer { isFileOperationActive = false }
        guard let client else {
            errorMessage = "上传失败：未连接到服务器，请重新连接后重试"
            return
        }

        let title = "正在上传"
        var succeeded = 0
        var failures: [String] = []

        for (index, url) in urls.enumerated() {
            let name = url.lastPathComponent
            batchProgress = BatchProgress(title: title, completed: index, total: urls.count,
                                          detail: name, transferredBytes: 0, totalBytes: 0)
            let reached = url.startAccessingSecurityScopedResource()
            defer { if reached { url.stopAccessingSecurityScopedResource() } }
            do {
                // iOS 26 上 security-scoped URL 偶发 Data(contentsOf:) 直接读失败（"无权查看该文件"）。
                // 先直读；失败则把文件复制到 App 临时目录再读，绕开对原始作用域 URL 的直接访问。
                let data: Data
                do {
                    data = try Data(contentsOf: url)
                } catch {
                    let temp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("LonePanel-upload-\(UUID().uuidString)")
                        .appendingPathComponent(name)
                    try FileManager.default.createDirectory(at: temp.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: temp.deletingLastPathComponent()) }
                    try FileManager.default.copyItem(at: url, to: temp)
                    data = try Data(contentsOf: temp)
                }
                let totalBytes = Int64(data.count)
                try await client.writeFile(client.joined(directory, name), data: data) { written in
                    Task { @MainActor [weak self] in
                        self?.batchProgress = BatchProgress(
                            title: title, completed: index, total: urls.count,
                            detail: name, transferredBytes: written, totalBytes: totalBytes
                        )
                    }
                }
                succeeded += 1
            } catch {
                failures.append("\(name)：\(SSHSession.describe(error))")
            }
        }

        // 完成态停留约 0.8 秒让用户看清，再清除 HUD。
        batchProgress = BatchProgress(title: title, completed: urls.count, total: urls.count,
                                      detail: failures.isEmpty ? "完成" : "部分失败",
                                      transferredBytes: 0, totalBytes: 0)
        try? await Task.sleep(nanoseconds: 800_000_000)
        if batchProgress?.title == title { batchProgress = nil }

        // 明确的成功/失败反馈——此前成功无任何提示、失败只在逐文件 catch 里，
        // 小文件秒传时进度 HUD 一闪而过，用户感知就是「点了没反应」。
        if failures.isEmpty {
            errorMessage = succeeded == 1 ? "已上传 1 个文件" : "已上传 \(succeeded) 个文件"
        } else {
            let ok = succeeded > 0 ? "成功 \(succeeded) 个；" : ""
            errorMessage = "上传结束：\(ok)失败 \(failures.count) 个。\(failures.joined(separator: "\n"))"
        }
        // 只要有文件成功写入，就通知各级目录页刷新，让新文件立即出现在列表里。
        if succeeded > 0 { refreshToken &+= 1 }
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
