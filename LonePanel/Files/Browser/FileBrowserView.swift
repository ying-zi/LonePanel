import SwiftUI
import QuickLook
import UIKit
import UniformTypeIdentifiers

/// 对齐 iOS 26/27 系统「文件」App 的浏览器：
/// - 逐层 push 导航，左上角沿用系统原生返回箭头（顶层不显示、子层级显示）；
/// - 标题下拉为系统原生 Menu，列出从根目录到当前的层级，点击任一极跳转；
/// - 列表 / 图标网格两种视图，系统默认行样式，每一个条目整行可点；
/// - 长按上下文菜单、左滑操作、多选态浮动玻璃工具条；
/// - 单击文件走系统 QuickLook，分享走系统分享面板；拷贝→粘贴走共享剪贴板。
struct FileBrowserView: View {
    /// 单例模型：导航栈与连接状态跨 Tab 切换存活。
    /// 调用态（容器卷管理）注入独立实例，入口态用 shared。
    @ObservedObject private var model: FileBrowserModel
    @ObservedObject private var session = ServerSession.shared
    @Environment(\.scenePhase) private var scenePhase

    /// 调用态关闭动作：非 nil 时在工具栏最右显示 chevron.down 关闭按钮（sheet 形态用）。
    /// 入口态为 nil——文件 Tab 是常驻页面，没有"关闭"概念。
    private let callClose: (() -> Void)?

    /// 入口态初始化（shared 单例）。调用态用 init(model:callClose:) 注入独立实例。
    init() {
        self._model = ObservedObject(wrappedValue: FileBrowserModel.shared)
        self.callClose = nil
    }

    /// 调用态初始化：注入独立 model（由调用方 @StateObject 持有），复用完整文件操作 UI。
    init(model: FileBrowserModel, callClose: (() -> Void)? = nil) {
        self._model = ObservedObject(wrappedValue: model)
        self.callClose = callClose
    }

    /// NavigationStack 导航栈：根不进 path。存放于单例 model，切走再回来停留在原目录。
    /// 系统原生返回由 NavigationStack 管理。
    @State private var previewURL: URL? = nil
    @State private var shareItem: ShareItem? = nil

    /// 栈底标题：真根 "/" 显示服务器名，默认目录显示其末级目录名。
    private var rootTitle: String {
        model.rootPath == "/" ? model.serverName : (model.rootPath as NSString).lastPathComponent
    }

    var body: some View {
        Group {
            // 只要配置了服务器且未连接失败，就固定呈现 NavigationStack：连接过程与
            // 目录加载都由页内同一段加载态承接。过去在 TabView 根层另放一段 spinner，
            // 会被系统套上材质圆角块（浅灰方块），且冷启动时与页内「加载中…」形成两段
            // 动画跳变。现在根层只有这一分支，加载态与列表同处 NavigationStack 内，
            // 背景与底色完全一致，从连接到出列表只有一次连续过渡。
            if model.hasConfiguredServer && !model.connectionFailed {
                NavigationStack(path: $model.navPath) {
                    DirectoryPage(
                        model: model,
                        // 栈底 = 默认目录（未设则是真根 "/"）。iOS 26 点当前 Tab 会把
                        // NavigationStack 系统级 pop 到栈底，落点自然就是默认目录。
                        node: FileNode(path: model.rootPath, title: rootTitle),
                        previewURL: $previewURL,
                        shareItem: $shareItem,
                        navPath: $model.navPath,
                        callClose: callClose
                    )
                    // rootPath 变化（冷启动定位 / 切服务器 / 点服务器名回真根 / 设默认归位）
                    // 时重建根页，确保其 .task 重新加载新栈底目录。
                    .id(model.rootPath)
                    .navigationDestination(for: FileNode.self) { node in
                        DirectoryPage(
                            model: model,
                            node: node,
                            previewURL: $previewURL,
                            shareItem: $shareItem,
                            navPath: $model.navPath,
                            callClose: callClose
                        )
                    }
                }
                // 搜索框下放到每个 DirectoryPage：系统为每一级目录各自提供一个原生放大镜，
                // 点开即在「当前页」呈现搜索框并自动聚焦，不会再出现「按钮消失、框不出」。
                // 各页搜索状态独立，互不串味；切层级时随页面销毁自然收起，无残留、无闪烁。
            } else {
                disconnectedView
            }
        }
        // 列表之外的兜底背景：铺满全屏、忽略键盘安全区。键盘弹起/收起时列表外区域
        // 始终露出同一背景色，减少"白块跳动"。列表本身恢复系统原生 grouped 样式，
        // 由系统绘制整组大圆角卡片，与 Docker 容器页共用同一套语义色。
        .background(
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea(.keyboard)
        )
        .task {
            await model.connectIfNeeded()
            // 仅首次连接时建立默认目录导航链；切回 Tab 不重置，保留离开前的目录。
            if model.isConnected { model.initializeNavigationIfNeeded() }
        }
        .onChange(of: session.currentServer?.id) { _, _ in
            // 切换服务器是明确的新会话，重置到新服务器的默认目录入口。
            Task { await model.reconnect(); model.resetNavigationToEntry() }
        }
        // 离开 App 较久后返回：静默重连并刷新当前列表（保留导航层级与界面快照）。
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, model.hasConfiguredServer else { return }
            Task {
                await model.reconnectSilently()
                // 成功后递增 refreshToken，各 DirectoryPage 监听后刷新当前目录。
            }
        }
        // 上传改用 UIKit 的 UIDocumentPickerViewController：delegate 回调不随 SwiftUI
        // 视图重建丢失（选文件时 App 会进后台，切回时 FileBrowserView 可能重建，
        // SwiftUI .fileImporter 的 completion 因此丢失，表现为「选完没反应」）。
        // asCopy 让系统把文件复制进 App 沙箱，直接可读，绕开 iOS 26 security-scope 读取失败。
        .fullScreenCover(isPresented: $model.isUploadPickerPresented, onDismiss: {
            // 兜底：无论选择器是点取消、下拉关闭还是选完文件，
            // 都要解除「文件操作进行中」标记，否则会永久抑制回前台静默重连。
            model.endFileOperation()
        }) {
            FileUploadPicker(
                onPick: { urls in
                    // 先关 cover，再异步上传；回调里同步置位关闭选择器界面。
                    model.isUploadPickerPresented = false
                    let target = model.uploadTargetDirectory
                    Task { @MainActor in
                        guard !urls.isEmpty else { model.endFileOperation(); return }
                        await model.upload(files: urls, to: target)
                        model.endFileOperation()
                        // asCopy 产生的是沙箱临时副本，上传后清理，避免 Inbox 累积。
                        for url in urls { try? FileManager.default.removeItem(at: url) }
                    }
                },
                onCancel: {
                    model.isUploadPickerPresented = false
                    model.endFileOperation()
                }
            )
        }
        .quickLookPreview($previewURL)
        .sheet(item: $shareItem) { ActivityShareSheet(items: $0.urls) }
        .alert(L10n.t("Action Notice"), isPresented: errorBinding) {
            Button(L10n.t("OK"), role: .cancel) { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
        // 批量传输进度：多文件/大文件夹粘贴、移动、复制时显示原生磨砂 HUD。
        .overlay { batchProgressHUD }
    }

    /// 批量操作进度浮层。
    /// - 有准确总字节（单文件复制）：进度条按字节渲染，文件名左侧 + 已传 KB 右侧。
    /// - 有总项数（多文件/目录）：进度条按项数渲染，同样在文件名右侧显示已传 KB。
    /// - 都没有（SSH 回退）：旋转指示器 + 不确定文案。
    @ViewBuilder
    private var batchProgressHUD: some View {
        if let progress = model.batchProgress {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Text(progress.title)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    if progress.total > 0 {
                        Text(L10n.f("%@/%@ items", String(describing: (progress.completed)), String(describing: (progress.total))))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if progress.totalBytes > 0 {
                    // 字节级进度：这是用户能看到的连续进度，修复过去进度条一直空白的问题。
                    ProgressView(value: Double(progress.transferredBytes),
                                 total: Double(progress.totalBytes))
                        .progressViewStyle(.linear)
                } else if progress.total > 0 {
                    ProgressView(value: Double(progress.completed), total: Double(progress.total))
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                }

                // 文件名在左，已传 KB 在右，实时刷新。
                HStack(spacing: 8) {
                    Text(progress.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if progress.transferredBytes > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: progress.transferredBytes,
                                                       countStyle: .file))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: 300)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 12, y: 4)
            .allowsHitTesting(false)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var disconnectedView: some View {
        NavigationStack {
            ContentUnavailableView {
                Label(L10n.t("Not Connected"), systemImage: "server.rack")
            } description: {
                Text(L10n.t("Add and connect a server in Settings > My Servers, then retry"))
            } actions: {
                Button(L10n.t("Reconnect")) { Task { await model.reconnect() } }
                    .buttonStyle(.borderedProminent)
            }
            // 未连接时也要能进设置：否则「只开文件模块 + 无服务器」会把用户锁死。
            // 齿轮并入本导航栏 trailing；调用态下自动隐藏。
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SettingsGearButton()
                }
                if let callClose {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: callClose) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .help(L10n.t("Close"))
                    }
                }
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.dismissError() } })
    }
}

/// 单一目录层级页面。自己的条目、搜索、多选与弹窗状态互不干扰，返回上层天然保留。
private struct DirectoryPage: View {
    @ObservedObject var model: FileBrowserModel
    let node: FileNode
    @Binding var previewURL: URL?
    @Binding var shareItem: ShareItem?
    @Binding var navPath: [FileNode]
    /// 调用态关闭动作（透传自 FileBrowserView.callClose），入口态为 nil。
    let callClose: (() -> Void)?

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var entries: [RemoteFile] = []
    @State private var isLoading = false
    /// 是否至少成功加载过一次。区分「尚未加载」与「加载完确实为空」，消除首帧空白页闪现。
    @State private var hasLoadedOnce = false
    @State private var isSelecting = false

    /// 每页独立的搜索状态：系统为每一级目录各自提供原生放大镜，
    /// 点开即在「当前页」呈现搜索框并自动聚焦，各页互不串味。
    @State private var searchText = ""
    @State private var isSearching = false
    @FocusState private var searchFocused: Bool

    /// 不支持在线预览的文件给出提示，确认后再下载 + 系统分享。
    @State private var previewNotice: String?
    @State private var pendingNoticeFile: RemoteFile?
    @State private var selectedIDs: Set<RemoteFile.ID> = []

    // 操作弹窗状态
    @State private var pendingCreateFolder = false
    @State private var newFolderName = ""
    @State private var pendingCreateFile = false
    @State private var newFileName = ""
    @State private var renaming: RemoteFile?
    @State private var renameText = ""
    @State private var deleting: [RemoteFile] = []
    @State private var showDangerConfirm = false
    @State private var showDeleteConfirm = false
    @State private var infoFile: RemoteFile?
    /// 正在编辑的文本文件（仅文本 / 代码类型）。sheet 承载原生 TextEditor。
    @State private var editingFile: RemoteFile?
    @State private var targetOperation: BatchOperation?
    @State private var targetFiles: [RemoteFile] = []
    /// 压缩：记录待压缩项 + 归档名输入。
    @State private var compressFiles: [RemoteFile] = []
    @State private var archiveName = ""
    @State private var archiveFormat: FileBrowserModel.ArchiveFormat = .tarGz
    @State private var pendingCompress = false
    /// 解压：待解压的归档文件（确认后解压到当前目录）。
    @State private var extractFile: RemoteFile?
    @State private var pendingExtract = false

    var body: some View {
        pageContent
            .navigationBarTitleDisplayMode(.inline)
            // 搜索栏挂在「每一页」上：系统为根页与每个 push 的子页各自注入原生放大镜，
            // 点开即在当前页呈现搜索框。各页状态独立，切层级随页面退出自然收起。
            .searchable(text: $searchText, isPresented: $isSearching, prompt: Text(L10n.t("Search")))
            .searchFocused($searchFocused)
            // iOS 26：未聚焦时收缩，消除列表顶部常驻的灰色搜索条。
            .searchToolbarBehavior(.minimize)
            .onChange(of: isSearching) { _, searching in
                if searching {
                    searchFocused = true
                } else {
                    // 只清关键词；焦点与键盘的 resign 完全交给系统"取消"流程，
                    // 不手动改 FocusState（否则与系统动画撞成双重 dismiss）。
                    searchText = ""
                }
            }
            // 方案一：搜索态绑定在页上，离开即放弃。
            // 搜索框展开时点了列表里的文件夹 push 下一级 → 导航栈深度增加，
            // 说明用户用「点目录」这个明确动作放弃了对当前层的搜索；清掉本页搜索态，
            // 返回时便是搜索框关闭、列表恢复完整的干净状态（不再残留搜索框）。
            // 只在新页入栈（count 增大）且本页正处于搜索态时清；返回（count 减小）不动。
            // 不碰 searchFocused —— isPresented 置 false 后系统自行 resign，
            // 避开「键盘还在时双重 dismiss」导致的底部白区上顶闪烁。
            .onChange(of: navPath.count) { oldCount, newCount in
                if newCount > oldCount, isSearching {
                    isSearching = false
                    searchText = ""
                }
            }
            .refreshable { await load() }
            .task { await load() }
            // 断线重连成功后重新拉取当前目录（保留导航层级与选中态）。
            .onChange(of: model.refreshToken) { _, _ in Task { await load() } }
            // 连接未建立时隐藏工具栏：此时的 ⋯ / 搜索等操作都依赖尚未就绪的连接，
            // 显示出来只会点了没反应。连接成功后随 isConnected 一起原生恢复。
            .toolbar {
                if model.isConnected { toolbarContent }
            }
            // 多选 / 后台静默重连态隐藏系统返回键；搜索态的返回与「取消」交给系统接管。
            // 静默重连：由 leading 原位的转圈接管，避免在返回箭头旁再叠一个指示器。
            .navigationBarBackButtonHidden(isSelecting || model.isBackgroundReconnecting)
            // 多选栏用 overlay 悬浮在 TabBar 上方，不占安全区（避免 safeAreaInset
            // 在键盘 dismiss 时回弹导致底部露出不同色背景）。仅多选态显示。
            .overlay(alignment: .bottom) {
                if isSelecting {
                    batchActionBar
                        .padding(.bottom, 72)
                }
            }
            .background(dialogHost)
    }

    /// 所有弹窗集中在独立宿主，避免 body 的 modifier 链过长导致 type-check 超时。
    private var dialogHost: some View {
        Color.clear.frame(width: 0, height: 0)
        .alert(L10n.t("New folder"), isPresented: $pendingCreateFolder) {
            TextField(L10n.t("Folder Name"), text: $newFolderName)
            Button(L10n.t("Cancel"), role: .cancel) { newFolderName = "" }
            Button(L10n.t("Create")) {
                Task { await model.makeDirectory(at: node.path, named: newFolderName); newFolderName = ""; await load() }
            }
        }
        .alert(L10n.t("New file"), isPresented: $pendingCreateFile) {
            TextField(L10n.t("File Name"), text: $newFileName)
            Button(L10n.t("Cancel"), role: .cancel) { newFileName = "" }
            Button(L10n.t("Create")) {
                Task { await model.makeFile(at: node.path, named: newFileName); newFileName = ""; await load() }
            }
        }
        .alert(L10n.t("Rename"), isPresented: renameBinding) {
            TextField(L10n.t("Name"), text: $renameText)
            Button(L10n.t("Cancel"), role: .cancel) { renaming = nil }
            Button(L10n.t("Save")) {
                if let file = renaming {
                    let parent = (file.path as NSString).deletingLastPathComponent
                    Task { await model.rename(file, in: parent, to: renameText); renaming = nil; await load() }
                }
            }
        }
        .sheet(isPresented: $pendingCompress) {
            CompressSheet(name: $archiveName, format: $archiveFormat, itemCount: compressFiles.count) {
                let files = compressFiles
                let name = archiveName
                let fmt = archiveFormat
                Task {
                    await model.compress(files, in: node.path, named: name, format: fmt)
                    compressFiles = []
                    archiveName = ""
                    await load()
                }
            }
        }
        .alert(L10n.t("Extract"), isPresented: $pendingExtract) {
            Button(L10n.t("Cancel"), role: .cancel) { extractFile = nil }
            Button(L10n.t("Extract")) {
                if let file = extractFile {
                    Task { await model.extract(file, into: node.path); extractFile = nil; await load() }
                }
            }
        } message: {
            Text(L10n.f("Extract \"%@\" into the current folder?", String(describing: (extractFile?.name ?? ""))))
        }
        .alert(L10n.t("Delete Selected Items?"), isPresented: $showDeleteConfirm) {
            Button(L10n.t("Delete"), role: .destructive) {
                let filesToDelete = deleting
                Task {
                    await model.delete(filesToDelete)
                    deleting = []
                    resetSelection()
                    await load()
                }
            }
            Button(L10n.t("Cancel"), role: .cancel) { deleting = [] }
        } message: {
            Text(L10n.t("This cannot be undone. Make sure you have a backup."))
        }
        .alert(L10n.t("Danger Path"), isPresented: $showDangerConfirm) {
            Button(L10n.t("Yes, Continue Deleting"), role: .destructive) {
                showDangerConfirm = false
                showDeleteConfirm = true
            }
            Button(L10n.t("Cancel"), role: .cancel) { deleting = [] }
        } message: {
            Text(L10n.t("The selection is in a critical system directory (e.g. /etc, /usr). Deleting may break the system. Make sure you understand the consequences."))
        }
        .alert(L10n.t("Online preview unavailable"), isPresented: noticeBinding) {
            Button(L10n.t("Cancel"), role: .cancel) { pendingNoticeFile = nil; previewNotice = nil }
            Button(L10n.t("Download & Share")) {
                if let file = pendingNoticeFile {
                    Task { if let url = await model.localURL(for: file, purpose: "share") { shareItem = ShareItem(url: url) } }
                }
                pendingNoticeFile = nil
                previewNotice = nil
            }
        } message: {
            Text(previewNotice ?? "")
        }
        .sheet(item: $infoFile) { file in
            FileInfoSheet(file: file, model: model)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $editingFile) { file in
            TextEditorView(file: file, model: model) {
                Task { await load() }
            }
        }
        .sheet(isPresented: targetPickerBinding) {
            TargetDirectorySheet(model: model, node: node, operation: targetOperation ?? .move) { target in
                // 必须在创建 Task 前捕获值：@State 在 Task 执行时才读取，
                // 若先清空会在异步任务里拿到空数组，移动/复制变成空操作。
                let filesToTransfer = targetFiles
                let operationToApply = targetOperation ?? .move
                Task {
                    await model.transfer(filesToTransfer, operation: operationToApply, to: target)
                    await load()
                }
                targetOperation = nil
                targetFiles = []
                resetSelection()
            }
        }
    }

    /// 页面主体按状态分派，用 AnyView 抹平分支类型差异，避免 body 表达式过重。
    private var pageContent: some View {
        AnyView(contentForState)
    }

    @ViewBuilder
    private var contentForState: some View {
        if !model.isConnected || isLoading || !hasLoadedOnce {
            // 连接中、首帧与加载中共用同一段加载态 —— 这就是冷启动唯一的加载过程，
            // 不再有 TabView 根层那段独立的「正在连接服务器…」造成两段动画跳变。
            // 没有 hasLoadedOnce 时，新建的目录页首帧 isLoading=false、entries=[]，
            // 会先闪一帧「文件夹为空」的空白页 —— 回默认目录 push 多级导航链时
            // 每一级都闪，视觉上就是「跳到一个空白页」。
            connectionLoadingView
        } else if entries.isEmpty {
            emptyView
        } else if model.viewMode == .grid {
            gridView
        } else {
            listView
        }
    }

    /// 连接与目录加载共用的原生加载态：UIKit spinner 无背景块，文字为系统次级样式，
    /// 与列表同处 NavigationStack 内、底色一致，不会被套浅灰圆角块。
    private var connectionLoadingView: some View {
        VStack(spacing: 12) {
            NativeSpinner()
            Text(L10n.t("Loading…"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 加载与筛选

    private func load() async {
        // 连接尚未建立时 listDirectory 会直接返回空；若此时写入 hasLoadedOnce
        // 会闪现「文件夹为空」。保持加载态，等连接成功后 refreshToken 变化再拉取。
        guard model.isConnected else { return }
        isLoading = true
        defer { isLoading = false }
        entries = await model.listDirectory(at: node.path)
        hasLoadedOnce = true
    }

    private var visibleEntries: [RemoteFile] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(keyword) }
    }

    private var allVisibleSelected: Bool {
        !visibleEntries.isEmpty && selectedIDs.count == visibleEntries.count
    }

    // MARK: - 列表视图（系统默认行样式，整行可点）

    private var listView: some View {
        List {
            ForEach(visibleEntries) { file in
                rowView(for: file)
            }
            if isSelecting {
                // 多选栏悬浮在底部，补占位避免遮住最后一行；仅多选态出现。
                Color.clear.frame(height: 150)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        // 恢复系统原生分组卡片：整组一个大圆角卡、行间细分隔线（iOS 设置页同款），
        // 比"每行一张小卡"更连贯耐看。卡片色由系统按浅/深色自动取 secondarySystemGroupedBackground。
        .listStyle(.insetGrouped)
        .overlay { if isLoading && !entries.isEmpty { ProgressView() } }
    }

    /// 每个条目用系统原生 NavigationLink / Button 承载点击 —— 整行都是热区，
    /// 而非只在文件名上挂 gesture。多选态改为切换选中的 Button。
    @ViewBuilder
    private func rowView(for file: RemoteFile) -> some View {
        Group {
            if isSelecting {
                Button { toggleSelection(file) } label: {
                    FileRow(file: file, isSelected: selectedIDs.contains(file.id), showsCheckmark: true,
                            progress: model.transferProgress[file.path])
                }
                .buttonStyle(.plain)
            } else if file.isDirectory {
                NavigationLink(value: FileNode(path: file.path, title: file.name)) {
                    FileRow(file: file, progress: model.transferProgress[file.path])
                }
            } else {
                Button { quickLook(file) } label: {
                    FileRow(file: file, progress: model.transferProgress[file.path])
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            }
        }
        .contentShape(Rectangle())
        .contextMenu { contextMenuItems(for: file) }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isSelecting {
                // 左滑只留高频动作：可编辑文本多一个「编辑」，其余只有「删除」。
                // 重命名 / 移动收敛到长按菜单，避免左滑三个按钮的拥挤与误触。
                if FileKind.isEditable(file) {
                    Button { editingFile = file } label: {
                        Label(L10n.t("Edit"), systemImage: "square.and.pencil")
                    }
                    .tint(.blue)
                }
                Button(role: .destructive) { requestDelete([file]) } label: {
                    Label(L10n.t("Delete"), systemImage: "trash")
                }
            }
        }
    }

    // MARK: - 图标网格视图（整行/整格可点）

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .compact ? 84 : 110), spacing: 16)], spacing: 20) {
                ForEach(visibleEntries) { file in
                    gridCell(for: file)
                }
            }
            .padding()
            if isSelecting {
                // 多选栏悬浮在底部，补占位避免遮住最后一行；仅多选态出现。
                Color.clear.frame(height: 150)
            }
        }
        .overlay { if isLoading && !entries.isEmpty { ProgressView() } }
    }

    @ViewBuilder
    private func gridCell(for file: RemoteFile) -> some View {
        Group {
            if isSelecting {
                Button { toggleSelection(file) } label: {
                    GridFileCell(file: file, isSelected: selectedIDs.contains(file.id),
                                 progress: model.transferProgress[file.path])
                }
                .buttonStyle(.plain)
            } else if file.isDirectory {
                NavigationLink(value: FileNode(path: file.path, title: file.name)) {
                    GridFileCell(file: file, progress: model.transferProgress[file.path])
                }
                .buttonStyle(.plain)
            } else {
                Button { quickLook(file) } label: {
                    GridFileCell(file: file, progress: model.transferProgress[file.path])
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            }
        }
        .contentShape(Rectangle())
        .contextMenu { contextMenuItems(for: file) }
    }

    private var emptyView: some View {
        ContentUnavailableView {
            Label(searchText.isEmpty ? L10n.t("Folder is Empty") : L10n.t("No Results"),
                  systemImage: searchText.isEmpty ? "folder" : "magnifyingglass")
        } description: {
            Text(searchText.isEmpty ? L10n.t("This folder is empty") : L10n.t("Try another keyword"))
        }
    }

    // MARK: - 顶部工具栏（系统返回箭头 · 标题原生 Menu · ⋯）

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if model.isBackgroundReconnecting && !isSelecting && !isSearching {
                // 后台切回前台静默重连：在返回按钮原位显示同等大小的转圈，
                // 保留界面快照；连接是非确定过程，用循环动画而非线性进度条。
                ProgressView()
                    .frame(width: 24, height: 24)
            } else if isSelecting {
                Button(allVisibleSelected ? L10n.t("Deselect All") : L10n.t("Select All")) {
                    if allVisibleSelected { selectedIDs = [] }
                    else { selectedIDs = Set(visibleEntries.map(\.id)) }
                }
            }
            // 其余情况 leading 留空：系统原生返回箭头显示（根页自动隐藏）。
            // 搜索态同样留空，避免出现一个随返回箭头转场的透明占位白点。
        }
        ToolbarItem(placement: .principal) {
            // 搜索态时系统会把标题位替换为原生搜索框，此处让位留空；
            // 多选态显示选中计数，其余显示标题层级 Menu。
            if !isSearching {
                ZStack {
                    titleMenu
                        .opacity(!isSelecting ? 1 : 0)
                        .allowsHitTesting(!isSelecting)
                    Text(L10n.f("%@ items", String(describing: (selectedIDs.count)))).font(.headline)
                        .opacity(isSelecting ? 1 : 0)
                        .allowsHitTesting(isSelecting)
                }
            }
        }
        // 与 Docker / 数据库 / 终端统一：右上角每个按钮各占一个独立 ToolbarItem，
        // 由 iOS 26 系统按标准 tap 宽度排成玻璃胶囊，不再用 HStack 手动定间距。
        // 设置齿轮恒在最右，入口态（单模块全屏）才出现。
        ToolbarItem(placement: .topBarTrailing) {
            if isSelecting {
                // 完成按钮：纯大勾，无自定义背景色，颜色与系统搜索按钮一致（主色）。
                // 背景交给 iOS 26 工具栏的玻璃胶囊，避免蓝底方块与胶囊叠在一起显突兀。
                Button { resetSelection() } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
            } else {
                // 搜索栏已挂到每一页，系统为根页与每个子页各自提供原生放大镜，
                // 不再自定义放大镜按钮 —— 从根上杜绝「双放大镜」与
                // 「点了自定义放大镜却不出搜索框、按钮反而消失」的问题。
                // 只保留 ⋯，常驻不随搜索态消失。
                moreMenu
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            SettingsGearButton()
        }
        // 调用态（sheet）：最右关闭按钮；入口态 callClose 为 nil，不显示。
        if let callClose {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: callClose) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 16, weight: .semibold))
                }
                .help(L10n.t("Close"))
                .accessibilityLabel(L10n.t("Close"))
            }
        }
    }

    /// 标题下拉：主标题仍显示当前目录名；点开后首项恒为服务器名称，
    /// 点击回到服务器真正的根目录 "/"（用于重新挑默认目录）；
    /// 其余层级从栈底（默认目录）起列，不再展开 "/" 到默认目录间的祖先。
    private var titleMenu: some View {
        Menu {
            // 首项恒定：当前服务器名 → 回真根 "/"。
            Button {
                model.navigateToTrueRoot()
            } label: {
                Label(model.serverName, systemImage: "server.rack")
            }
            Divider()
            // 层级：从栈底（默认目录 / 真根）到当前的每一级。
            ForEach(Array(levelNodes.enumerated()), id: \.offset) { idx, level in
                Button {
                    jumpToLevel(idx)
                } label: {
                    Label(level.title,
                          systemImage: idx == currentLevel ? "checkmark" : (idx == 0 ? "folder" : "folder.fill"))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(node.title).font(.headline).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.primary)
        }
    }

    /// 层级节点：第 0 项是栈底（默认目录；真根时标题为服务器名），其后是 navPath。
    /// 默认目录以上的祖先不在此列，回真根统一走首项服务器名按钮。
    private var levelNodes: [FileNode] {
        [FileNode(path: model.rootPath, title: stackBottomTitle)] + navPath
    }

    private var stackBottomTitle: String {
        model.rootPath == "/" ? model.serverName : (model.rootPath as NSString).lastPathComponent
    }

    private var currentLevel: Int { navPath.count }

    /// 跳到指定层级：截断 navPath 到该深度。idx=0（栈底）即清空导航栈。
    private func jumpToLevel(_ idx: Int) {
        guard idx < navPath.count else { return }
        navPath = Array(navPath.prefix(idx))
        model.clearClipboard()
    }

    private var moreMenu: some View {
        Menu {
            Button {
                searchText = ""
                isSearching = false
                isSelecting = true
                selectedIDs = []
            } label: {
                Label(L10n.t("Choose"), systemImage: "checkmark.circle")
            }
            Button {
                newFileName = ""
                pendingCreateFile = true
            } label: {
                Label(L10n.t("New file"), systemImage: "doc.badge.plus")
            }
            Button {
                newFolderName = ""
                pendingCreateFolder = true
            } label: {
                Label(L10n.t("New folder"), systemImage: "folder.badge.plus")
            }
            Button {
                // 记录目标目录并置位 picker：picker 由导航栈顶层统一承载，
                // 不挂在会被 push/pop 重建的目录页上，completion 才不会丢失。
                model.uploadTargetDirectory = node.path
                model.beginFileOperation()
                model.isUploadPickerPresented = true
            } label: {
                Label(L10n.t("Upload File"), systemImage: "square.and.arrow.up.on.square")
            }
            // 粘贴：剪贴板非空时显示，把已拷贝的项目复制到当前目录。
            if !model.clipboard.isEmpty {
                Button {
                    Task { await pasteHere() }
                } label: {
                    Label(L10n.f("Paste (%@ items)", String(describing: (model.clipboard.count))), systemImage: "doc.on.clipboard")
                }
            }
            Divider()
            Menu {
                ForEach(FileSortOrder.allCases) { order in
                    Button {
                        model.sortOrder = order
                        Task { await load() }
                    } label: {
                        if model.sortOrder == order {
                            Label(L10n.t(order.rawValue), systemImage: "checkmark")
                        } else {
                            Text(L10n.t(order.rawValue))
                        }
                    }
                }
                Divider()
                Button {
                    model.sortAscending.toggle()
                    Task { await load() }
                } label: {
                    Label(model.sortAscending ? L10n.t("Ascending") : L10n.t("Descending"),
                          systemImage: model.sortAscending ? "arrow.up" : "arrow.down")
                }
            } label: {
                Label(L10n.t("Sort By"), systemImage: "arrow.up.arrow.down")
            }
            Button {
                withAnimation { model.viewMode = model.viewMode == .list ? .grid : .list }
            } label: {
                Label(model.viewMode == .list ? L10n.t("Icon View") : L10n.t("List View"),
                      systemImage: model.viewMode == .list ? "square.grid.2x2" : "list.bullet")
            }
            Divider()
            Button {
                model.showHiddenFiles.toggle()
                Task { await load() }
            } label: {
                Label(model.showHiddenFiles ? L10n.t("Hide Hidden Files") : L10n.t("Show Hidden Files"),
                      systemImage: model.showHiddenFiles ? "eye.slash" : "eye")
            }
            Button {
                model.setAsDefaultDirectory(node.path)
            } label: {
                Label(L10n.t("Set as Default Directory"), systemImage: "folder.badge.gearshape")
            }
            Button {
                Task { await model.reconnect(); await load() }
            } label: {
                Label(L10n.t("Reconnect"), systemImage: "arrow.clockwise")
            }
        } label: {
            // 系统文件 App 的更多按钮是裸三点，不套圆圈。
            Image(systemName: "ellipsis")
                .font(.title3)
        }
    }

    // MARK: - 长按上下文菜单（顶部快捷三连）

    @ViewBuilder
    private func contextMenuItems(for file: RemoteFile) -> some View {
        ControlGroup {
            Button { model.copyToClipboard([file]) } label: {
                Label(L10n.t("Copy"), systemImage: "doc.on.doc")
            }
            Button { beginTransfer(.move, files: [file]) } label: {
                Label(L10n.t("Move"), systemImage: "arrow.right")
            }
            // 共享需先把文件下载为本地文件；目录无法作为单文件分享，故仅对文件显示。
            if !file.isDirectory {
                Button { share(file) } label: {
                    Label(L10n.t("Share"), systemImage: "square.and.arrow.up")
                }
            }
        }
        Divider()
        // 快速查看（QuickLook）仅对文件有效，目录改用进入浏览（整行点击）。
        if !file.isDirectory {
            Button { quickLook(file) } label: { Label(L10n.t("Quick Look"), systemImage: "eye") }
        }
        // 只有纯文本 / 源码且在大小上限内，才提供编辑入口。
        if FileKind.isEditable(file) {
            Button { editingFile = file } label: { Label(L10n.t("Edit"), systemImage: "square.and.pencil") }
        }
        Button { infoFile = file } label: { Label(L10n.t("Get Info"), systemImage: "info.circle") }
        Button { renameTarget(file) } label: { Label(L10n.t("Rename"), systemImage: "pencil") }
        // 归档文件提供解压；其余项提供压缩（单文件也会打成 .tar.gz）。
        if FileKind.isArchive(file) {
            Button { extractTarget(file) } label: { Label(L10n.t("Extract"), systemImage: "doc.zipper") }
        } else {
            Button { compressTarget([file]) } label: { Label(L10n.t("Compress"), systemImage: "doc.zipper") }
        }
        Divider()
        Button(role: .destructive) { requestDelete([file]) } label: {
            Label(L10n.t("Delete"), systemImage: "trash")
        }
    }

    // MARK: - 多选底部浮动玻璃工具条

    /// 多选底部工具条：图标 + 文字标签的大按钮，均分宽度、约 60pt 高，方便拇指点击。
    private var batchActionBar: some View {
        HStack(spacing: 4) {
            // 共享仅对「选中项全部是文件」有效：只要勾选了文件夹就不显示
            // （目录无法作为单文件分享，混选时也不宜把文件夹静默丢掉）。
            if !selectedFiles.isEmpty && selectedFiles.allSatisfy({ !$0.isDirectory }) {
                batchIcon("square.and.arrow.up", title: L10n.t("Share")) { shareSelected() }
            }
            batchIcon("arrow.right", title: L10n.t("Move")) { beginTransfer(.move, files: selectedFiles) }
            batchIcon("doc.on.doc", title: L10n.t("Copy")) { copySelected() }
            // 归档项提供解压（仅单选归档时），其余提供压缩。
            if selectedFiles.count == 1, let only = selectedFiles.first, FileKind.isArchive(only) {
                batchIcon("doc.zipper", title: L10n.t("Extract")) { extractTarget(only) }
            } else {
                batchIcon("doc.zipper", title: L10n.t("Compress")) { compressTarget(selectedFiles) }
            }
            batchIcon("trash", title: L10n.t("Delete"), role: .destructive) { requestDelete(selectedFiles) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
        }
        .shadow(radius: 14, y: 6)
        .disabled(selectedIDs.isEmpty)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// 单个批量按钮：图标在上、文字在下，整块约 52pt 高可点。
    private func batchIcon(_ name: String, title: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 4) {
                Image(systemName: name).font(.title3)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 操作辅助

    private func quickLook(_ file: RemoteFile) {
        if !FileKind.supportsQuickLook(file) {
            // 归档/未知类型系统无法在线预览：记录待分享文件，先弹提示，
            // 用户确认后再下载并打开系统分享面板，避免提示与分享面板同时弹出。
            pendingNoticeFile = file
            previewNotice = "\"\(file.name)\" cannot be previewed online. It will be downloaded and opened in the Share sheet."
            return
        }
        Task { if let url = await model.localURL(for: file, purpose: "preview") { previewURL = url } }
    }

    private func share(_ file: RemoteFile) {
        Task { if let url = await model.localURL(for: file, purpose: "share") { shareItem = ShareItem(url: url) } }
    }

    /// 多选共享：把选中的多个文件下载到本地，一次分享（目录无法作为单文件分享，自动跳过）。
    private func shareSelected() {
        Task {
            var urls: [URL] = []
            for file in selectedFiles where !file.isDirectory {
                if let url = await model.localURL(for: file, purpose: "share") { urls.append(url) }
            }
            if !urls.isEmpty { shareItem = ShareItem(urls: urls) }
        }
    }

    /// 拷贝选中项到共享剪贴板，退出多选态。
    private func copySelected() {
        model.copyToClipboard(selectedFiles)
        resetSelection()
    }

    /// 把剪贴板内容粘贴到当前目录并刷新。
    private func pasteHere() async {
        await model.pasteClipboard(into: node.path)
        await load()
    }

    private func toggleSelection(_ file: RemoteFile) {
        if selectedIDs.contains(file.id) { selectedIDs.remove(file.id) }
        else { selectedIDs.insert(file.id) }
    }

    private func resetSelection() {
        isSelecting = false
        selectedIDs = []
    }

    private var selectedFiles: [RemoteFile] {
        entries.filter { selectedIDs.contains($0.id) }
    }

    private func renameTarget(_ file: RemoteFile) {
        renaming = file
        renameText = file.name
    }

    /// 压缩：默认归档名取当前目录名或首项名，进入输入弹窗确认。
    private func compressTarget(_ files: [RemoteFile]) {
        guard !files.isEmpty else { return }
        compressFiles = files
        let base = (node.path as NSString).lastPathComponent
        // 名称框只填主名；后缀由下方格式下拉决定，避免「选了 zip 名字却还是 .tar.gz」的误解。
        archiveName = base.isEmpty ? "archive" : base
        // 每次进入按当前格式重置后缀（默认 tar.gz），与名称框主名分离。
        archiveFormat = .tarGz
        pendingCompress = true
    }

    /// 解压：记录目标归档，进入确认弹窗。
    private func extractTarget(_ file: RemoteFile) {
        extractFile = file
        pendingExtract = true
    }

    private func requestDelete(_ files: [RemoteFile]) {
        guard !files.isEmpty else { return }
        deleting = files
        if files.contains(where: { FileBrowserModel.isDangerousPath($0.path) }) {
            showDangerConfirm = true
        } else {
            showDeleteConfirm = true
        }
    }

    private func beginTransfer(_ operation: BatchOperation, files: [RemoteFile]) {
        guard !files.isEmpty else { return }
        targetOperation = operation
        targetFiles = files
    }

    // MARK: - 绑定辅助

    private var renameBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }
    private var targetPickerBinding: Binding<Bool> {
        Binding(get: { targetOperation != nil }, set: { if !$0 { targetOperation = nil; targetFiles = [] } })
    }
    private var noticeBinding: Binding<Bool> {
        Binding(get: { previewNotice != nil }, set: { if !$0 { previewNotice = nil } })
    }
}

/// 单行文件条目：系统图标 + 名称 + 元信息；撑满整行使整行都可点。
private struct FileRow: View {
    let file: RemoteFile
    var isSelected = false
    var showsCheckmark = false
    /// 下载进度（0...1），非 nil 时在行底部显示系统原生线性进度条。
    var progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 20) {
                if showsCheckmark {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }
                // 图标与右侧两行文字等高：系统文件 App 的列表图标约 34pt。
                Image(systemName: FileKind(file: file).systemImage)
                    .font(.system(size: 34))
                    .frame(width: 34, alignment: .leading)
                    .foregroundStyle(FileKind(file: file).tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.body)
                        .lineLimit(1)
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var meta: String {
        // 跟随 App 内语言（非系统 locale），且带时分秒。
        let date = file.modified.map { L10n.dateTimeText($0) } ?? ""
        if file.isDirectory { return date.isEmpty ? L10n.t("Folder") : date }
        let size = FileBrowserModel.sizeText(file.size)
        return date.isEmpty ? size : L10n.f("%@ · %@", String(describing: (date)), String(describing: (size)))
    }
}

/// 图标网格单元：大图标 + 文件名，撑满整格可点。
private struct GridFileCell: View {
    let file: RemoteFile
    var isSelected = false
    var progress: Double?

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: FileKind(file: file).systemImage)
                    .font(.system(size: 40))
                    .foregroundStyle(FileKind(file: file).tint)
                    .frame(maxWidth: .infinity, minHeight: 48)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
            }
            Text(file.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10))
    }
}

/// 移动/复制的目标目录选择：系统原生列表逐级浏览，点"移动/复制"到当前目录。
private struct TargetDirectorySheet: View {
    @ObservedObject var model: FileBrowserModel
    let node: FileNode
    let operation: BatchOperation
    let onConfirm: (String) -> Void

    @State private var path: String = "/"
    @State private var dirs: [RemoteFile] = []
    @State private var isLoading = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && dirs.isEmpty {
                    ProgressView(L10n.t("Loading…"))
                } else {
                    List {
                        ForEach(dirs) { dir in
                            Button {
                                path = dir.path
                                Task { await load() }
                            } label: {
                                Label(dir.name, systemImage: "folder.fill")
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(L10n.t("Choose Location"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            guard path != "/" else { return }
                            path = (path as NSString).deletingLastPathComponent
                            if path.isEmpty { path = "/" }
                            Task { await load() }
                        } label: {
                            Image(systemName: "arrow.up.folder")
                        }
                        .disabled(path == "/")
                        Button(L10n.t(operation.rawValue)) {
                            onConfirm(path)
                            dismiss()
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
            .task {
                path = node.path
                await load()
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let all = await model.listDirectory(at: path)
        dirs = all.filter(\.isDirectory)
    }
}

/// 基于 UIKit `UIDocumentPickerViewController` 的文件选择器。
/// 相比 SwiftUI `.fileImporter` 的优势（针对「选完没反应」）：
/// - delegate 回调绑定在 Representable 的 Coordinator 上，选文件时 App 进后台、
///   切回时外层视图重建也不会丢失回调；
/// - `asCopy: true` 让系统把选中文件复制进 App 沙箱，返回的是本进程可直接读取的 URL，
///   绕开 iOS 26 上 security-scoped URL `Data(contentsOf:)` 偶发失败的问题；
/// - `.item` 作为类型覆盖任意文件（含 iCloud 云文件），由系统负责按需下载。
struct FileUploadPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    /// UIDocumentPicker 直接作为 fullScreenCover 的根 VC —— 它自带导航、取消与选择按钮，
    /// 这种呈现方式最标准、最少层级，delegate 回调稳定。
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {
        context.coordinator.onPick = onPick
        context.coordinator.onCancel = onCancel
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onPick: (([URL]) -> Void)?
        var onCancel: (() -> Void)?

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            onPick?(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel?()
        }
    }
}

/// 系统原生 spinner：用 UIKit 的 UIActivityIndicatorView，避免 SwiftUI ProgressView
/// 被套上材质背景块。它是 iOS 系统各处通用的原生加载指示器，本身不带任何背景。
private struct NativeSpinner: UIViewRepresentable {
    func makeUIView(context: Context) -> UIActivityIndicatorView {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = .tertiaryLabel
        spinner.startAnimating()
        return spinner
    }

    func updateUIView(_ uiView: UIActivityIndicatorView, context: Context) {}
}

/// 压缩参数表：输入主名 + 后缀下拉（网页款式），实时预览最终完整文件名。
/// 用独立 sheet（而非 alert）承载，SwiftUI alert 里放 Picker/Menu 渲染不可靠。
private struct CompressSheet: View {
    @Binding var name: String
    @Binding var format: FileBrowserModel.ArchiveFormat
    let itemCount: Int
    let onCompress: () -> Void
    @Environment(\.dismiss) private var dismiss

    /// 由 name 去掉用户可能手填的后缀 + 当前格式后缀，拼出最终真实文件名。
    private var finalName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var base = trimmed
        for suffix in [".tar.gz", ".tgz", ".zip"] {
            if base.hasSuffix(suffix) { base = String(base.dropLast(suffix.count)); break }
        }
        if base.isEmpty { base = "archive" }
        return base + format.displayName
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.t("Archive Name")) {
                    // 名称框 + 后缀下拉拼成一行：网页那种「输入框后面跟后缀选择」的款式，
                    // Menu 用原生样式弹出，与 iOS 系统风格一致，不会冲突。
                    HStack(spacing: 8) {
                        TextField(L10n.t("Archive Name"), text: $name)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Menu {
                            ForEach(FileBrowserModel.ArchiveFormat.allCases) { f in
                                Button {
                                    format = f
                                } label: {
                                    if f == format {
                                        Label(f.displayName, systemImage: "checkmark")
                                    } else {
                                        Text(f.displayName)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Text(format.displayName)
                                    .foregroundStyle(.tint)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(.tint)
                            }
                            .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                Section {
                    // 实时预览：切换后缀或改名时立即更新，彻底消除「选了 zip 却是 .tar.gz」的误解。
                    LabeledContent(L10n.t("File Name")) {
                        Text(finalName)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    Text(L10n.f("Compress %@ selected items into this folder.", String(describing: itemCount)))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(L10n.t("Compress"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Compress")) {
                        onCompress()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
