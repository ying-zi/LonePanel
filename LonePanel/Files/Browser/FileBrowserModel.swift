import SwiftUI
import Foundation

/// Files 浏览器的状态与操作。只依赖根 Core 的会话/SSH/钥匙串能力，
/// 以及 Files/Core 的 SFTP、默认目录存储与文件类型；不认识 Settings 等任何其他模块。
@MainActor
final class FileBrowserModel: ObservableObject {
    // MARK: - 连接与列表
    @Published private(set) var entries: [RemoteFile] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isConnected = false
    @Published var searchText = ""
    @Published var errorMessage: String?

    /// 从根 "/" 到当前目录的逐级路径，供顶部路径摘要浮层使用。
    @Published private(set) var pathSegments: [PathSegment] = []
    /// 当前所在目录绝对路径。
    @Published private(set) var currentPath = "/"

    // MARK: - 详情
    /// 正在查看详情的文件（非 nil 时以 sheet/navigation 呈现详情）。
    @Published var detailFile: RemoteFile?
    @Published var detailBytes: Data?
    @Published var detailEncoding: FileTextEncoding = .utf8
    @Published var detailLoadFailed = false
    @Published var isEditing = false
    @Published var editBuffer = ""
    @Published var showDiscardConfirm = false

    // MARK: - 路径浮层
    @Published var showPathMenu = false

    // MARK: - 多选与批量
    @Published var isSelecting = false
    @Published var selectedIDs: Set<RemoteFile.ID> = []
    @Published var batchOperation: BatchOperation?
    @Published var showBatchConfirm = false

    // MARK: - 操作弹窗
    @Published var showHiddenFiles = false
    @Published var pendingCreateFolder = false
    @Published var newFolderName = ""
    @Published var renaming: RemoteFile?
    @Published var renameText = ""
    /// 待删除的文件（单个或批量）。
    @Published var deleting: [RemoteFile] = []
    /// 危险路径二次确认是否显示。
    @Published var showDangerConfirm = false
    /// 目标目录选择（移动/复制用）。
    @Published var targetPickerOperation: BatchOperation?
    @Published var targetPickerFiles: [RemoteFile] = []
    @Published var targetPath = "/"
    @Published var targetEntries: [RemoteFile] = []
    @Published var targetIsLoading = false

    private var client: SFTPClient?
    private var connectedServerID: UUID?

    var serverName: String { ServerSession.shared.currentServer?.name ?? "未连接" }

    /// 当前目录显示名（路径摘要最后一级）。
    var currentDisplayName: String {
        pathSegments.last?.name ?? "服务器文件"
    }

    /// 路径摘要文本：根目录显示"根目录"，否则显示末两级 "… / root / current"。
    var pathSummary: String {
        if pathSegments.count <= 1 { return "根目录" }
        let lastTwo = pathSegments.suffix(2).map(\.name)
        return "… / " + lastTwo.joined(separator: " / ")
    }

    var visibleEntries: [RemoteFile] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = entries
        if !showHiddenFiles {
            result = result.filter { !$0.name.hasPrefix(".") }
        }
        guard !keyword.isEmpty else { return result }
        return result.filter { $0.name.localizedCaseInsensitiveContains(keyword) }
    }

    var allVisibleSelected: Bool {
        !visibleEntries.isEmpty && selectedIDs.count == visibleEntries.count
    }

    // MARK: - 连接与冷启动

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

            // 进入规则：未设默认目录进 "/"，已设则进默认目录。
            let start = DefaultDirectoryStore.path(for: info.id) ?? "/"
            await navigate(to: start)
            isConnected = true
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
        entries = []
        pathSegments = []
        currentPath = "/"
        resetSelection()
    }

    /// 单击当前文件 Tab：无条件回到默认目录入口。
    func returnToDefaultEntry() {
        guard let info = ServerSession.shared.currentServer, isConnected else { return }
        let start = DefaultDirectoryStore.path(for: info.id) ?? "/"
        Task { await navigate(to: start) }
    }

    // MARK: - 导航

    /// 跳转到任意绝对路径，并重建从根到该级的路径摘要层级。
    func navigate(to path: String) async {
        let normalized = path.isEmpty ? "/" : path
        currentPath = normalized
        pathSegments = Self.segments(for: normalized)
        resetSelection()
        await loadCurrent()
    }

    /// 由当前路径拆解出从根到当前的逐级 PathSegment。
    static func segments(for path: String) -> [PathSegment] {
        var result: [PathSegment] = []
        if path == "/" {
            return [PathSegment(name: "根目录", path: "/")]
        }
        result.append(PathSegment(name: "根目录", path: "/"))
        let components = path.split(separator: "/").map(String.init)
        var accumulated = ""
        for component in components {
            accumulated += "/" + component
            result.append(PathSegment(name: component, path: accumulated))
        }
        return result
    }

    func enter(_ file: RemoteFile) {
        guard file.isDirectory else { return }
        Task { await navigate(to: file.path) }
    }

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

    // MARK: - 设置默认目录

    func setAsDefaultDirectory() {
        guard let info = ServerSession.shared.currentServer else { return }
        DefaultDirectoryStore.set(currentPath, for: info.id)
    }

    // MARK: - 文件列表操作

    func createFolder() async {
        guard let client, !newFolderName.isEmpty else { return }
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let target = client.joined(currentPath, name)
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

    /// 发起删除请求；命中危险路径时先弹二次确认，否则走普通确认。
    func requestDelete(_ files: [RemoteFile]) {
        if files.contains(where: { Self.isDangerousPath($0.path) }) {
            deleting = files
            showDangerConfirm = true
        } else {
            deleting = files
        }
    }

    /// 危险路径二次确认通过后，进入普通删除确认（两级确认）。
    func acceptDangerAndContinueDelete() {
        showDangerConfirm = false
    }

    /// 危险路径清单：这些目录本身及其直接子级属于系统关键位置，删除需格外谨慎。
    static let dangerPaths: Set<String> = [
        "/etc", "/usr", "/bin", "/sbin", "/lib", "/lib64", "/boot",
        "/dev", "/proc", "/sys", "/var", "/root", "/System", "/Library", "/private"
    ]

    static func isDangerousPath(_ path: String) -> Bool {
        let clean = path.hasSuffix("/") ? String(path.dropLast()) : path
        if dangerPaths.contains(clean) { return true }
        // 命中某个危险目录的直接或更深子级。
        return dangerPaths.contains { clean.hasPrefix($0 + "/") }
    }

    func confirmDelete() async {
        guard let client, !deleting.isEmpty else { return }
        do {
            for file in deleting {
                if file.isDirectory {
                    try await client.removeDirectory(file.path)
                } else {
                    try await client.removeFile(file.path)
                }
            }
            deleting = []
            await loadCurrent()
        } catch {
            errorMessage = SSHSession.describe(error)
        }
    }

    // MARK: - 多选

    func toggleSelection(_ file: RemoteFile) {
        if selectedIDs.contains(file.id) {
            selectedIDs.remove(file.id)
        } else {
            selectedIDs.insert(file.id)
        }
    }

    func selectAll() {
        selectedIDs = Set(visibleEntries.map(\.id))
    }

    func resetSelection() {
        isSelecting = false
        selectedIDs = []
    }

    var selectedFiles: [RemoteFile] {
        entries.filter { selectedIDs.contains($0.id) }
    }

    // MARK: - 目标目录选择（移动/复制）

    func beginTransfer(_ operation: BatchOperation, files: [RemoteFile]) {
        targetPickerOperation = operation
        targetPickerFiles = files
        targetPath = currentPath
        Task { await loadTargetDirectory() }
    }

    func loadTargetDirectory() async {
        guard let client else { return }
        targetIsLoading = true
        defer { targetIsLoading = false }
        do {
            targetEntries = try await client.listDirectory(targetPath).filter(\.isDirectory)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            errorMessage = SSHSession.describe(error)
        }
    }

    func enterTarget(_ dir: RemoteFile) {
        targetPath = dir.path
        Task { await loadTargetDirectory() }
    }

    func goUpTarget() {
        guard targetPath != "/" else { return }
        let parent = (targetPath as NSString).deletingLastPathComponent
        targetPath = parent.isEmpty ? "/" : parent
        Task { await loadTargetDirectory() }
    }

    /// 执行批量移动/复制：借 SSH exec 调用远端 mv/cp，命令逐路径转义。
    func confirmTransfer() async {
        guard let client, let operation = targetPickerOperation, !targetPickerFiles.isEmpty else { return }
        let sources = targetPickerFiles.map { shellQuote($0.path) }.joined(separator: " ")
        let command: String
        switch operation {
        case .move:
            command = "mv -f \(sources) \(shellQuote(targetPath))"
        case .copy:
            command = "cp -R -f \(sources) \(shellQuote(targetPath))"
        }
        do {
            let result = try await client.execute(command)
            if result.exitStatus != 0 {
                throw SFTPError.malformed(result.stderr.isEmpty ? "命令执行失败" : result.stderr)
            }
            targetPickerOperation = nil
            targetPickerFiles = []
            resetSelection()
            await loadCurrent()
        } catch {
            errorMessage = SSHSession.describe(error)
        }
    }

    // MARK: - 批量压缩

    /// 将选中条目打包为当前目录下的 zip，借 SSH exec 执行。
    func compressSelected() async {
        guard let client, !selectedFiles.isEmpty else { return }
        let names = selectedFiles.map { shellQuote($0.name) }.joined(separator: " ")
        let stamp = Int(Date().timeIntervalSince1970)
        let archive = "archive-\(stamp).zip"
        let command = "cd \(shellQuote(currentPath)) && zip -r -q \(shellQuote(archive)) \(names)"
        do {
            let result = try await client.execute(command)
            if result.exitStatus != 0 {
                throw SFTPError.malformed(result.stderr.isEmpty ? "压缩失败" : result.stderr)
            }
            resetSelection()
            await loadCurrent()
        } catch {
            errorMessage = SSHSession.describe(error)
        }
    }

    // MARK: - 详情

    /// 打开详情：先下载字节，文本/图片分别按类别呈现。
    func openDetail(_ file: RemoteFile) async {
        detailFile = file
        detailEncoding = .utf8
        detailLoadFailed = false
        isEditing = false
        await reloadDetailBytes()
    }

    func reloadDetailBytes() async {
        guard let client, let file = detailFile else { return }
        detailLoadFailed = false
        do {
            detailBytes = try await client.readFile(file.path)
            if isEditing { editBuffer = detailText ?? "" }
        } catch {
            detailBytes = nil
            detailLoadFailed = true
            errorMessage = SSHSession.describe(error)
        }
    }

    func closeDetail() {
        if isEditing {
            showDiscardConfirm = true
            return
        }
        detailFile = nil
        detailBytes = nil
    }

    func forceCloseDetail() {
        isEditing = false
        detailFile = nil
        detailBytes = nil
        showDiscardConfirm = false
    }

    /// 按当前编码把字节解码为文本。
    var detailText: String? {
        guard let data = detailBytes else { return nil }
        return String(data: data, encoding: detailEncoding.stringEncoding)
    }

    var detailImage: UIImage? {
        guard let data = detailBytes else { return nil }
        return UIImage(data: data)
    }

    func beginEditing() {
        editBuffer = detailText ?? ""
        isEditing = true
    }

    /// 保存编辑：按当前编码把文本写回远端。
    func saveEditing() async {
        guard let client, let file = detailFile else { return }
        guard let data = editBuffer.data(using: detailEncoding.stringEncoding) else {
            errorMessage = "当前编码无法保存这些文字，请切换编码后重试"
            return
        }
        do {
            try await client.writeFile(file.path, data: data)
            isEditing = false
            await reloadDetailBytes()
            await loadCurrent()
        } catch {
            errorMessage = SSHSession.describe(error)
        }
    }

    /// 把当前详情文件导出到临时目录，交给系统分享面板。
    func exportURL() -> URL? {
        guard let data = detailBytes, let file = detailFile else { return nil }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(file.name)
        do {
            try FileManager.default.createDirectory(
                at: temp.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: temp)
            return temp
        } catch {
            errorMessage = "导出失败：\(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - 错误处理绑定辅助

    func dismissError() { errorMessage = nil }
}
