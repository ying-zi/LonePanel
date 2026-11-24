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
    @ObservedObject private var model = FileBrowserModel.shared
    @ObservedObject private var session = ServerSession.shared
    @Environment(\.scenePhase) private var scenePhase

    /// NavigationStack 导航栈：根不进 path。存放于单例 model，切走再回来停留在原目录。
    /// 系统原生返回由 NavigationStack 管理。
    @State private var previewURL: URL?
    @State private var shareItem: ShareItem?

    /// 栈底标题：真根 "/" 显示服务器名，默认目录显示其末级目录名。
    private var rootTitle: String {
        model.rootPath == "/" ? model.serverName : (model.rootPath as NSString).lastPathComponent
    }

    var body: some View {
        Group {
            if model.isConnected {
                NavigationStack(path: $model.navPath) {
                    DirectoryPage(
                        model: model,
                        // 栈底 = 默认目录（未设则是真根 "/"）。iOS 26 点当前 Tab 会把
                        // NavigationStack 系统级 pop 到栈底，落点自然就是默认目录。
                        node: FileNode(path: model.rootPath, title: rootTitle),
                        previewURL: $previewURL,
                        shareItem: $shareItem,
                        navPath: $model.navPath
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
                            navPath: $model.navPath
                        )
                    }
                }
                // 搜索框下放到每个 DirectoryPage：系统为每一级目录各自提供一个原生放大镜，
                // 点开即在「当前页」呈现搜索框并自动聚焦，不会再出现「按钮消失、框不出」。
                // 各页搜索状态独立，互不串味；切层级时随页面销毁自然收起，无残留、无闪烁。
            } else if model.hasConfiguredServer && !model.connectionFailed {
                // 已配置服务器、正在连接（尚未失败）：显示原生加载动画。
                ProgressView("正在连接服务器…")
            } else {
                disconnectedView
            }
        }
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
        .alert("操作提示", isPresented: errorBinding) {
            Button("好", role: .cancel) { model.dismissError() }
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
                        Text("\(progress.completed)/\(progress.total) 项")
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
        ContentUnavailableView {
            Label("未连接服务器", systemImage: "server.rack")
        } description: {
            Text("请在「设置 → 我的服务器」中添加并连接一台服务器，然后重试")
        } actions: {
            Button("重新连接") { Task { await model.reconnect() } }
                .buttonStyle(.borderedProminent)
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
    @State private var targetOperation: BatchOperation?
    @State private var targetFiles: [RemoteFile] = []

    var body: some View {
        pageContent
            .navigationBarTitleDisplayMode(.inline)
            // 搜索栏挂在「每一页」上：系统为根页与每个 push 的子页各自注入原生放大镜，
            // 点开即在当前页呈现搜索框。各页状态独立，切层级随页面退出自然收起。
            .searchable(text: $searchText, isPresented: $isSearching, prompt: "搜索")
            .searchFocused($searchFocused)
            // iOS 26：未聚焦时收缩，消除列表顶部常驻的灰色搜索条。
            .searchToolbarBehavior(.minimize)
            .onChange(of: isSearching) { _, searching in
                if searching {
                    searchFocused = true
                } else {
                    searchText = ""
                    searchFocused = false
                }
            }
            .refreshable { await load() }
            .task { await load() }
            // 断线重连成功后重新拉取当前目录（保留导航层级与选中态）。
            .onChange(of: model.refreshToken) { _, _ in Task { await load() } }
            .toolbar { toolbarContent }
            // 多选 / 后台静默重连态隐藏系统返回键；搜索态的返回与「取消」交给系统接管。
            // 静默重连：由 leading 原位的转圈接管，避免在返回箭头旁再叠一个指示器。
            .navigationBarBackButtonHidden(isSelecting || model.isBackgroundReconnecting)
            .safeAreaInset(edge: .bottom) { if isSelecting { batchActionBar } }
            .background(dialogHost)
    }

    /// 所有弹窗集中在独立宿主，避免 body 的 modifier 链过长导致 type-check 超时。
    private var dialogHost: some View {
        Color.clear.frame(width: 0, height: 0)
        .alert("新建文件夹", isPresented: $pendingCreateFolder) {
            TextField("文件夹名称", text: $newFolderName)
            Button("取消", role: .cancel) { newFolderName = "" }
            Button("创建") {
                Task { await model.makeDirectory(at: node.path, named: newFolderName); newFolderName = ""; await load() }
            }
        }
        .alert("新建文件", isPresented: $pendingCreateFile) {
            TextField("文件名", text: $newFileName)
            Button("取消", role: .cancel) { newFileName = "" }
            Button("创建") {
                Task { await model.makeFile(at: node.path, named: newFileName); newFileName = ""; await load() }
            }
        }
        .alert("重命名", isPresented: renameBinding) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) { renaming = nil }
            Button("保存") {
                if let file = renaming {
                    let parent = (file.path as NSString).deletingLastPathComponent
                    Task { await model.rename(file, in: parent, to: renameText); renaming = nil; await load() }
                }
            }
        }
        .alert("删除所选项目？", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) {
                let filesToDelete = deleting
                Task {
                    await model.delete(filesToDelete)
                    deleting = []
                    resetSelection()
                    await load()
                }
            }
            Button("取消", role: .cancel) { deleting = [] }
        } message: {
            Text("删除后无法恢复，请确认已备份重要数据。")
        }
        .alert("危险路径", isPresented: $showDangerConfirm) {
            Button("我确认，继续删除", role: .destructive) {
                showDangerConfirm = false
                showDeleteConfirm = true
            }
            Button("取消", role: .cancel) { deleting = [] }
        } message: {
            Text("所选内容位于系统关键目录（如 /etc、/usr）。删除可能导致系统异常，请务必确认你清楚后果。")
        }
        .alert("无法在线预览", isPresented: noticeBinding) {
            Button("取消", role: .cancel) { pendingNoticeFile = nil; previewNotice = nil }
            Button("下载并分享") {
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
        if isLoading || !hasLoadedOnce {
            // 首帧与加载中都显示加载态。没有 hasLoadedOnce 时，新建的目录页
            // 首帧 isLoading=false、entries=[]，会先闪一帧「文件夹为空」的空白页 ——
            // 回默认目录 push 多级导航链时每一级都闪，视觉上就是「跳到一个空白页」。
            ProgressView("加载中…")
        } else if entries.isEmpty {
            emptyView
        } else if model.viewMode == .grid {
            gridView
        } else {
            listView
        }
    }

    // MARK: - 加载与筛选

    private func load() async {
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
        }
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
                Button { renameTarget(file) } label: { Label("重命名", systemImage: "pencil") }
                    .tint(.orange)
                Button(role: .destructive) { requestDelete([file]) } label: {
                    Label("删除", systemImage: "trash")
                }
                Button { beginTransfer(.move, files: [file]) } label: {
                    Label("移动", systemImage: "arrow.right")
                }
                .tint(.blue)
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
            Label(searchText.isEmpty ? "文件夹为空" : "无搜索结果",
                  systemImage: searchText.isEmpty ? "folder" : "magnifyingglass")
        } description: {
            Text(searchText.isEmpty ? "此目录中没有内容" : "试试其他关键词")
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
                Button(allVisibleSelected ? "取消全选" : "全选") {
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
                    Text("\(selectedIDs.count) 项").font(.headline)
                        .opacity(isSelecting ? 1 : 0)
                        .allowsHitTesting(isSelecting)
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if isSelecting {
                // 完成按钮：蓝色圆角矩形底 + 白色大勾，不用圆圈包勾。
                Button { resetSelection() } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 9))
                }
            } else {
                // 搜索栏已挂到每一页，系统为根页与每个子页各自提供原生放大镜，
                // 不再自定义放大镜按钮 —— 从根上杜绝「双放大镜」与
                // 「点了自定义放大镜却不出搜索框、按钮反而消失」的问题。
                // 只保留 ⋯，常驻不随搜索态消失。
                moreMenu
                    .padding(.trailing, 8)
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
                Label("选择", systemImage: "checkmark.circle")
            }
            Button {
                newFileName = ""
                pendingCreateFile = true
            } label: {
                Label("新建文件", systemImage: "doc.badge.plus")
            }
            Button {
                newFolderName = ""
                pendingCreateFolder = true
            } label: {
                Label("新建文件夹", systemImage: "folder.badge.plus")
            }
            Button {
                // 记录目标目录并置位 picker：picker 由导航栈顶层统一承载，
                // 不挂在会被 push/pop 重建的目录页上，completion 才不会丢失。
                model.uploadTargetDirectory = node.path
                model.beginFileOperation()
                model.isUploadPickerPresented = true
            } label: {
                Label("上传文件", systemImage: "square.and.arrow.up.on.square")
            }
            // 粘贴：剪贴板非空时显示，把已拷贝的项目复制到当前目录。
            if !model.clipboard.isEmpty {
                Button {
                    Task { await pasteHere() }
                } label: {
                    Label("粘贴（\(model.clipboard.count) 项）", systemImage: "doc.on.clipboard")
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
                            Label(order.rawValue, systemImage: "checkmark")
                        } else {
                            Text(order.rawValue)
                        }
                    }
                }
                Divider()
                Button {
                    model.sortAscending.toggle()
                    Task { await load() }
                } label: {
                    Label(model.sortAscending ? "升序" : "降序",
                          systemImage: model.sortAscending ? "arrow.up" : "arrow.down")
                }
            } label: {
                Label("排序方式", systemImage: "arrow.up.arrow.down")
            }
            Button {
                withAnimation { model.viewMode = model.viewMode == .list ? .grid : .list }
            } label: {
                Label(model.viewMode == .list ? "图标视图" : "列表视图",
                      systemImage: model.viewMode == .list ? "square.grid.2x2" : "list.bullet")
            }
            Divider()
            Button {
                model.showHiddenFiles.toggle()
                Task { await load() }
            } label: {
                Label(model.showHiddenFiles ? "隐藏隐藏文件" : "显示隐藏文件",
                      systemImage: model.showHiddenFiles ? "eye.slash" : "eye")
            }
            Button {
                model.setAsDefaultDirectory(node.path)
            } label: {
                Label("设为默认访问目录", systemImage: "folder.badge.gearshape")
            }
            Button {
                Task { await model.reconnect(); await load() }
            } label: {
                Label("重新连接", systemImage: "arrow.clockwise")
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
                Label("拷贝", systemImage: "doc.on.doc")
            }
            Button { beginTransfer(.move, files: [file]) } label: {
                Label("移动", systemImage: "arrow.right")
            }
            // 共享需先把文件下载为本地文件；目录无法作为单文件分享，故仅对文件显示。
            if !file.isDirectory {
                Button { share(file) } label: {
                    Label("共享", systemImage: "square.and.arrow.up")
                }
            }
        }
        Divider()
        // 快速查看（QuickLook）仅对文件有效，目录改用进入浏览（整行点击）。
        if !file.isDirectory {
            Button { quickLook(file) } label: { Label("快速查看", systemImage: "eye") }
        }
        Button { infoFile = file } label: { Label("获取信息", systemImage: "info.circle") }
        Button { renameTarget(file) } label: { Label("重命名", systemImage: "pencil") }
        Divider()
        Button(role: .destructive) { requestDelete([file]) } label: {
            Label("删除", systemImage: "trash")
        }
    }

    // MARK: - 多选底部浮动玻璃工具条

    /// 多选底部工具条：图标 + 文字标签的大按钮，均分宽度、约 60pt 高，方便拇指点击。
    private var batchActionBar: some View {
        HStack(spacing: 4) {
            // 共享仅对「选中项全部是文件」有效：只要勾选了文件夹就不显示
            // （目录无法作为单文件分享，混选时也不宜把文件夹静默丢掉）。
            if !selectedFiles.isEmpty && selectedFiles.allSatisfy({ !$0.isDirectory }) {
                batchIcon("square.and.arrow.up", title: "共享") { shareSelected() }
            }
            batchIcon("arrow.right", title: "移动") { beginTransfer(.move, files: selectedFiles) }
            batchIcon("doc.on.doc", title: "拷贝") { copySelected() }
            batchIcon("trash", title: "删除", role: .destructive) { requestDelete(selectedFiles) }
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
            previewNotice = "「\(file.name)」不支持在线预览，确认后将下载并打开系统分享菜单。"
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
        let date = file.modified?.formatted(date: .abbreviated, time: .omitted) ?? ""
        if file.isDirectory { return date.isEmpty ? "文件夹" : date }
        let size = FileBrowserModel.sizeText(file.size)
        return date.isEmpty ? size : "\(date) · \(size)"
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
                    ProgressView("加载中…")
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
            .navigationTitle("选择位置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
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
                        Button(operation.rawValue) {
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
