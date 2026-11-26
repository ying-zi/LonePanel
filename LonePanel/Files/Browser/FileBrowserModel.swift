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

    /// 导航栈底路径（根页 path）：设了默认目录时就是默认目录，否则是 "/"。
    /// 关键设计：iOS 26 点当前 Tab 会把嵌套 NavigationStack 系统级 pop 到栈底，
    /// 因此把栈底本身设为默认目录，系统 pop 的结果天然就是「回默认目录」——
    /// 不再需要任何拦截、快照、代次、兜底定时器去对抗系统行为。
    @Published var rootPath: String = "/"
    /// 导航栈：根页不进栈，元素是栈底之后逐级 push 的目录节点。
    /// 放在单例 model 中，切换 Tab 不丢失，停留在离开前的目录。
    @Published var navPath: [FileNode] = []
    /// 是否已完成首次导航初始化：冷启动定位一次栈底，切回 Tab 不再重置。
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

    var serverName: String { ServerSession.shared.currentServer?.name ?? L10n.t("Server Files") }

    /// 冷启动/单击 Tab 回根时的入口路径：未设默认目录进 "/"。
    var entryPath: String {
        guard let id = ServerSession.shared.currentServer?.id else { return "/" }
        return DefaultDirectoryStore.path(for: id) ?? "/"
    }

    // MARK: - 导航栈管理

    /// 冷启动首次连接成功后，把导航栈底设为默认目录（未设则是 "/"/真根）。
    /// 只执行一次；此后切 Tab / 切回前台都不再改动，保留用户所处目录。
    func initializeNavigationIfNeeded() {
        guard !navigationInitialized else { return }
        navigationInitialized = true
        rootPath = entryPath
        navPath = []
    }

    /// 切到新服务器时：栈底换成新服务器的默认目录，清空导航栈。
    func resetNavigationToEntry() {
        navigationInitialized = true
        rootPath = entryPath
        navPath = []
        searchText = ""
        isSearching = false
    }

    /// 标题菜单点「服务器名称」：把栈底设成真正的根目录 "/"。
    /// 之后系统点当前 Tab pop 到栈底，落点就是 "/"（与菜单语义一致）。
    func navigateToTrueRoot() {
        rootPath = "/"
        navPath = []
        searchText = ""
        isSearching = false
    }

    /// 设为默认访问目录后归位：把该目录设为新的导航栈底并回到它。
    func setAsDefaultDirectory(_ path: String) {
        guard let id = ServerSession.shared.currentServer?.id else { return }
        DefaultDirectoryStore.set(path, for: id)
        rootPath = path
        navPath = []
        searchText = ""
        isSearching = false
    }


    // MARK: - 连接与冷启动

    func connectIfNeeded(force: Bool = false) async {
        guard let info = ServerSession.shared.currentServer else {
            clearSession()
            errorMessage = L10n.t("Add and connect a server in Settings > My Servers first")
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
            errorMessage = describeFileError(error)
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
            errorMessage = "Server connection failed: \(describeFileError(error))"
        }
    }

    // MARK: - 目录列表与排序

    func listDirectory(at path: String) async -> [RemoteFile] {
        guard let client else { return [] }
        do {
            let raw = try await client.listDirectory(path)
            return sortEntries(raw)
        } catch {
            errorMessage = describeFileError(error)
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
            errorMessage = L10n.t("Name cannot contain invalid characters like \"/\"")
            return nil
        }
        return trimmed
    }

    func makeDirectory(at path: String, named name: String) async {
        guard let client, let trimmed = validName(name) else { return }
        do {
            try await client.makeDirectory(client.joined(path, trimmed))
        } catch {
            errorMessage = describeFileError(error)
        }
    }

    func rename(_ file: RemoteFile, in parent: String, to newName: String) async {
        guard let client, let trimmed = validName(newName) else { return }
        do {
            try await client.rename(from: file.path, to: client.joined(parent, trimmed))
        } catch {
            errorMessage = describeFileError(error)
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
            errorMessage = reason.isEmpty ? L10n.t("Delete failed: server refused the operation") : L10n.f("Delete failed: %@", String(describing: (reason)))
        } catch {
            // exec 通道不可用（服务端禁用命令执行）：回退纯 SFTP 递归删除。
            do {
                for file in files { try await deleteRecursive(client, file) }
                refreshToken &+= 1
            } catch {
                errorMessage = describeFileError(error)
            }
        }
    }

    // MARK: - 压缩 / 解压（走远端 shell 命令，失败给出可读错误）

    /// 把选中的多项压缩成当前目录下的一个 .tar.gz 归档。
    /// 用 tar -czf，源项按 basename 引入（不带绝对路径），解压后不会套出整条路径。
    func compress(_ files: [RemoteFile], in directory: String, named name: String) async {
        guard let client, !files.isEmpty, let trimmed = validName(name) else { return }
        // 统一补 .tar.gz 后缀，避免用户漏写导致产物无扩展名、后续无法识别。
        let archiveName = trimmed.hasSuffix(".tar.gz") ? trimmed : trimmed + ".tar.gz"
        // basename 是相对「当前目录」的，tar 必须 -C 到当前目录再按 basename 取源，
        // 不能切到父目录（否则 Cannot stat）。产物用绝对路径写到当前目录，
        // 因明确列出 basename（非 "."），不会把正在生成的归档自身打进去。
        let basenames = files.map { shellQuote(($0.path as NSString).lastPathComponent) }.joined(separator: " ")
        let script = "tar -czf \(shellQuote(client.joined(directory, archiveName))) -C \(shellQuote(directory)) \(basenames)"
        do {
            let result = try await client.execute(script, timeoutSeconds: 120)
            if result.exitStatus == 0 {
                refreshToken &+= 1
            } else {
                let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                errorMessage = reason.isEmpty
                    ? L10n.t("Compress failed: server refused the operation")
                    : L10n.f("Compress failed: %@", String(describing: (reason)))
            }
        } catch {
            errorMessage = describeFileError(error)
        }
    }

    /// 把归档解压到指定目录。按扩展名选择工具，覆盖 tar/gz/bz2/xz/zip/7z/rar。
    func extract(_ file: RemoteFile, into directory: String) async {
        guard let client else { return }
        let ext = (file.name as NSString).pathExtension.lowercased()
        let src = shellQuote(file.path)
        let dst = shellQuote(directory)
        let command: String
        switch ext {
        case "zip":
            command = "unzip -o \(src) -d \(dst)"
        case "tar", "gz", "tgz":
            command = "tar -xzf \(src) -C \(dst)"
        case "bz2", "tbz2":
            command = "tar -xjf \(src) -C \(dst)"
        case "xz", "txz":
            command = "tar -xJf \(src) -C \(dst)"
        case "7z":
            command = "7z x -y -o\(dst) \(src)"
        case "rar":
            command = "unrar x -o+ \(src) \(dst)/"
        default:
            // 单文件 .gz（非 tar 包）：gunzip -c 输出到同目录去掉 .gz 的文件。
            command = "gzip -cd \(src) > \(shellQuote(client.joined(directory, (file.name as NSString).deletingPathExtension)))"
        }
        do {
            let result = try await client.execute(command, timeoutSeconds: 120)
            if result.exitStatus == 0 {
                refreshToken &+= 1
            } else {
                let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                errorMessage = reason.isEmpty
                    ? L10n.t("Extract failed: server refused the operation")
                    : L10n.f("Extract failed: %@", String(describing: (reason)))
            }
        } catch {
            errorMessage = describeFileError(error)
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
        let title = operation == .copy ? L10n.t("Copying") : L10n.t("Moving")
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
                                          detail: L10n.t("Done"), transferredBytes: 0, totalBytes: 0)
            return
        } catch {
            // 纯 SFTP 失败，继续尝试 SSH 命令回退（单条命令无法细分，显示不确定进度）。
            batchProgress = BatchProgress(title: L10n.f("%@ (server command)", String(describing: (title))), completed: 0,
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
                    ? L10n.f("%@ failed: server refused the operation", L10n.t(operation.rawValue))
                    : L10n.f("%@ failed: %@", L10n.t(operation.rawValue), reason)
            }
        } catch {
            errorMessage = describeFileError(error)
        }
    }

    /// 新建空文件：SFTP 以 creat|trunc|write 打开后即关闭，得到一个 0 字节文件。
    func makeFile(at path: String, named name: String) async {
        guard let client, let trimmed = validName(name) else { return }
        do {
            try await client.writeFile(client.joined(path, trimmed), data: Data())
        } catch {
            errorMessage = describeFileError(error)
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
                errorMessage = "\"\(file.name)\" is already in this folder and cannot be pasted here. Move it elsewhere first."
                return
            }
        }
        await transfer(clipboard, operation: .copy, to: target)
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
    /// 冷磁盘首次 du/find 遍历大目录可能很慢，超时放宽到 60 秒；一次扫描只发一条
    /// 合并命令降低往返。解析失败返回 nil，界面据此显示「扫描失败」并可重试。
    func folderStats(for file: RemoteFile) async -> FolderStats? {
        guard let client, file.isDirectory else { return nil }
        let path = shellQuote(file.path)
        // du -sk 输出「KB<TAB>路径」；find 统计不含目录自身，故子目录数 -1。
        // 三段各自兜底为 0，某条子命令失败（如服务器禁用 find）也不会让整条返回非 0。
        let script = "bytes=$(du -sk -- \(path) 2>/dev/null | awk '{print $1}'); "
            + "files=$(find \(path) -type f 2>/dev/null | wc -l); "
            + "dirs=$(find \(path) -type d 2>/dev/null | wc -l); "
            + "echo \"${bytes:-0}|${files:-0}|$(( ${dirs:-1} - 1 ))\""
        do {
            let result = try await client.execute(script, timeoutSeconds: 60)
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

    // MARK: - 属主名称（/etc/passwd 与 /etc/group → UID/GID 映射）

    /// 按当前服务器缓存的 UID→用户名、GID→组名映射。冷启动后首次按需加载。
    private var uidNames: [UInt32: String] = [:]
    private var gidNames: [UInt32: String] = [:]
    private var ownerNamesLoadedFor: UUID?

    /// 读取 /etc/passwd 与 /etc/group 建立映射。任一步失败则对应映射留空，
    /// 界面回退显示 UID/GID 数字。整个流程走 SFTP（不依赖 exec 通道）。
    func loadOwnerNamesIfNeeded() async {
        guard let client, let serverID = ServerSession.shared.currentServer?.id else { return }
        if ownerNamesLoadedFor == serverID { return }
        var users: [UInt32: String] = [:]
        var groups: [UInt32: String] = [:]
        if let data = try? await client.readFile("/etc/passwd"),
           let text = String(data: data, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let cols = line.split(separator: ":", omittingEmptySubsequences: false)
                // root:x:0:0:root:/root:/bin/bash → 名称 col0, UID col2, GID col3
                guard cols.count >= 3, let uid = UInt32(cols[2]) else { continue }
                users[uid] = String(cols[0])
            }
        }
        if let data = try? await client.readFile("/etc/group"),
           let text = String(data: data, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let cols = line.split(separator: ":", omittingEmptySubsequences: false)
                // root:x:0: → 名称 col0, GID col2
                guard cols.count >= 3, let gid = UInt32(cols[2]) else { continue }
                groups[gid] = String(cols[0])
            }
        }
        uidNames = users
        gidNames = groups
        ownerNamesLoadedFor = serverID
    }

    /// 把 UID/GID 解析成可读的「用户 · 组」；缺映射时回退为数字。
    func ownerDisplay(uid: UInt32?, gid: UInt32?) -> String {
        let user = uid.flatMap { uidNames[$0] } ?? uid.map { "UID \($0)" } ?? L10n.t("Unknown User")
        let group = gid.flatMap { gidNames[$0] } ?? gid.map { "GID \($0)" } ?? L10n.t("Unknown Group")
        return L10n.f("%@ · %@", String(describing: (user)), String(describing: (group)))
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
            errorMessage = L10n.t("Upload failed: not connected to server. Reconnect and retry.")
            return
        }

        let title = L10n.t("Uploading")
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
                failures.append("\(name)：\(describeFileError(error))")
            }
        }

        // 完成态停留约 0.8 秒让用户看清，再清除 HUD。
        batchProgress = BatchProgress(title: title, completed: urls.count, total: urls.count,
                                      detail: failures.isEmpty ? L10n.t("Done") : L10n.t("Partial Failure"),
                                      transferredBytes: 0, totalBytes: 0)
        try? await Task.sleep(nanoseconds: 800_000_000)
        if batchProgress?.title == title { batchProgress = nil }

        // 明确的成功/失败反馈——此前成功无任何提示、失败只在逐文件 catch 里，
        // 小文件秒传时进度 HUD 一闪而过，用户感知就是「点了没反应」。
        if failures.isEmpty {
            errorMessage = succeeded == 1 ? L10n.t("Uploaded 1 file") : L10n.f("Uploaded %@ files", String(describing: (succeeded)))
        } else {
            let ok = succeeded > 0 ? "\(succeeded) succeeded; " : ""
            errorMessage = "Upload finished: \(ok) failed \(failures.count). \(failures.joined(separator: "\n"))"
        }
        // 只要有文件成功写入，就通知各级目录页刷新，让新文件立即出现在列表里。
        if succeeded > 0 { refreshToken &+= 1 }
    }

    // MARK: - 预览与导出（QuickLook / 系统分享面板）

    /// 缓存 key：含服务器、路径、大小、修改时间，远端变化即失效，切服务器不串味。
    static func cacheKey(for file: RemoteFile) -> String {
        let serverID = ServerSession.shared.currentServer?.id.uuidString ?? "unknown"
        let modified = file.modified?.timeIntervalSince1970 ?? 0
        return "\(serverID)|\(file.path)|\(file.size)|\(modified)"
    }

    /// 返回远程文件可用的本地 URL，保留扩展名以便系统识别类型。
    /// 命中通用缓存则秒开（无下载、无进度条）；未命中才下载并写入缓存。
    /// key 含 服务器ID|路径|大小|修改时间：文件在服务端变化即失效重下，切服务器也不串味。
    /// purpose 保留以兼容调用方；预览与分享共用同一份缓存，不再按用途分目录。
    func localURL(for file: RemoteFile, purpose: String) async -> URL? {
        _ = purpose
        let key = Self.cacheKey(for: file)

        // 命中缓存：直接给出本地路径，跳过下载与进度条。
        if let cached = await FileCache.shared.url(forKey: key) { return cached }

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
            // 优先写入通用缓存（按 files 类别统计/清理）；万一写入失败，降级到临时目录，
            // 保证下载成功的文件仍能正常预览/分享。
            if let cached = await FileCache.shared.store(data, forKey: key,
                                                          category: "files", fileName: file.name) {
                return cached
            }
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("LonePanel-fallback", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(file.name)
            try data.write(to: url)
            return url
        } catch {
            errorMessage = describeFileError(error)
            return nil
        }
    }

    // MARK: - 文本编辑（读取 → UTF-8 解码 → 写回 → 失效缓存）

    /// 读取远端文本文件为 UTF-8 字符串。解码失败返回 nil，由编辑器提示用户。
    func readText(_ file: RemoteFile) async -> String? {
        guard let client else { return nil }
        do {
            let data = try await client.readFile(file.path, expectedSize: file.size)
            return String(data: data, encoding: .utf8)
        } catch {
            errorMessage = describeFileError(error)
            return nil
        }
    }

    /// 把编辑后的文本写回远端，成功后主动失效该文件的预览缓存并刷新列表。
    /// 返回 false 表示失败（错误已写入 errorMessage）。
    @discardableResult
    func writeText(_ text: String, to file: RemoteFile) async -> Bool {
        guard let client, let data = text.data(using: .utf8) else { return false }
        do {
            try await client.writeFile(file.path, data: data)
            // 修改时间与大小可能都没变（例如只改一个字符），旧 key 仍会命中，
            // 必须主动删掉缓存副本，否则预览/分享看到的还是旧内容。
            await FileCache.shared.remove(forKey: Self.cacheKey(for: file))
            refreshToken &+= 1
            return true
        } catch {
            errorMessage = describeFileError(error)
            return false
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

/// 文件模块统一的错误文案：SFTP 层错误自带人话（权限/不存在/超时等），直接呈现；
/// 其余 SSH/NIO 底层错误交给 SSHSession.describe 翻译，绝不暴露原始报错。
/// 放在 Files 层而非 Core 层，避免 Core 反向依赖文件模块的 SFTPError。
private func describeFileError(_ error: Error) -> String {
    if let e = error as? SFTPError {
        return e.localizedDescription
    }
    return SSHSession.describe(error)
}
