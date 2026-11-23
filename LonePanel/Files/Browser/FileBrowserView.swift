import SwiftUI
import QuickLook

/// 对齐 iOS 26 系统「文件」App 的浏览器：
/// - NavigationStack 逐层 push 目录，子层级系统自带返回箭头；
/// - 大标题 + 原生工具栏（视图切换 / 选择 / 更多）；
/// - 列表 / 图标网格两种视图，系统默认行样式；
/// - 长按上下文菜单、左滑操作、多选态系统底部工具栏；
/// - 单击文件走系统 QuickLook，分享走系统分享面板。
struct FileBrowserView: View {
    @StateObject private var model = FileBrowserModel()
    @ObservedObject private var session = ServerSession.shared

    /// 目录导航栈：每 push 一层就是一个 FileNode，返回箭头由系统提供。
    @State private var navPath: [FileNode] = []
    /// QuickLook 预览的本地文件。
    @State private var previewURL: URL?
    /// 系统分享面板的本地文件。
    @State private var shareItem: ShareItem?

    var body: some View {
        Group {
            if model.isConnected {
                browserStack
            } else {
                disconnectedView
            }
        }
        .task { await model.connectIfNeeded() }
        .onChange(of: session.currentServer?.id) { _, _ in
            navPath = []
            previewURL = nil
            Task { await model.reconnect() }
        }
        // 单击当前文件 Tab：清空导航栈回到默认目录入口。
        .onReceive(TabNavigationCenter.shared.$resetRequest) { request in
            guard let request, request.tabID == "files" else { return }
            navPath = []
            previewURL = nil
        }
        .quickLookPreview($previewURL)
        .sheet(item: $shareItem) { ActivityShareSheet(item: $0.url) }
        .alert("操作提示", isPresented: errorBinding) {
            Button("好", role: .cancel) { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var browserStack: some View {
        NavigationStack(path: $navPath) {
            DirectoryPage(
                model: model,
                node: FileNode(path: model.entryPath, title: model.serverName),
                navPath: $navPath,
                previewURL: $previewURL,
                shareItem: $shareItem
            )
            .navigationDestination(for: FileNode.self) { node in
                DirectoryPage(
                    model: model,
                    node: node,
                    navPath: $navPath,
                    previewURL: $previewURL,
                    shareItem: $shareItem
                )
            }
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
    @Binding var navPath: [FileNode]
    @Binding var previewURL: URL?
    @Binding var shareItem: ShareItem?

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var entries: [RemoteFile] = []
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var isSelecting = false
    @State private var selectedIDs: Set<RemoteFile.ID> = []

    // 操作弹窗状态
    @State private var pendingCreateFolder = false
    @State private var newFolderName = ""
    @State private var renaming: RemoteFile?
    @State private var renameText = ""
    @State private var deleting: [RemoteFile] = []
    @State private var showDangerConfirm = false
    @State private var showDeleteConfirm = false
    @State private var infoFile: RemoteFile?
    @State private var targetOperation: BatchOperation?
    @State private var targetFiles: [RemoteFile] = []

    private var title: String { node.title }

    var body: some View {
        pageContent
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: "搜索")
            .refreshable { await load() }
            .task { await load() }
            .toolbar { toolbarContent }
            // 多选态底部系统工具栏
            .safeAreaInset(edge: .bottom) {
                if isSelecting { batchActionBar }
            }
        // 弹窗宿主挂到背景，拆开类型检查链
        .background(dialogHost)
    }

    /// 所有弹窗集中在独立的轻量宿主上，避免 body 的 modifier 链过长导致 type-check 超时。
    private var dialogHost: some View {
        Color.clear.frame(width: 0, height: 0)
        .alert("新建文件夹", isPresented: $pendingCreateFolder) {
            TextField("文件夹名称", text: $newFolderName)
            Button("取消", role: .cancel) { newFolderName = "" }
            Button("创建") {
                Task { await model.makeDirectory(at: node.path, named: newFolderName); newFolderName = ""; await load() }
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
        .confirmationDialog("删除所选项目？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                Task { await model.delete(deleting); deleting = []; await load() }
            }
            Button("取消", role: .cancel) { deleting = [] }
        }
        .confirmationDialog("危险路径", isPresented: $showDangerConfirm, titleVisibility: .visible) {
            Button("我确认，继续删除", role: .destructive) {
                showDangerConfirm = false
                showDeleteConfirm = true
            }
            Button("取消", role: .cancel) { deleting = [] }
        } message: {
            Text("所选内容位于系统关键目录（如 /etc、/usr）。删除可能导致系统异常，请务必确认你清楚后果。")
        }
        .sheet(item: $infoFile) { file in
            FileInfoSheet(file: file)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: targetPickerBinding) {
            TargetDirectorySheet(model: model, node: node, operation: targetOperation ?? .move) { target in
                Task { await model.transfer(targetFiles, operation: targetOperation ?? .move, to: target); await load() }
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
        if isLoading && entries.isEmpty {
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
        let result = await model.listDirectory(at: node.path)
        entries = result
    }

    private var visibleEntries: [RemoteFile] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(keyword) }
    }

    private var allVisibleSelected: Bool {
        !visibleEntries.isEmpty && selectedIDs.count == visibleEntries.count
    }

    // MARK: - 列表视图（系统默认行样式）

    private var listView: some View {
        List {
            ForEach(visibleEntries) { file in
                FileRow(file: file)
                    .contentShape(Rectangle())
                    .onTapGesture { activate(file) }
                    .contextMenu { contextMenuItems(for: file) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !isSelecting {
                            Button {
                                renameTarget(file)
                            } label: {
                                Label("重命名", systemImage: "pencil")
                            }
                            .tint(.orange)
                            Button(role: .destructive) {
                                requestDelete([file])
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button {
                                beginTransfer(.move, files: [file])
                            } label: {
                                Label("移动", systemImage: "arrow.right")
                            }
                            .tint(.blue)
                        }
                    }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if isLoading && !entries.isEmpty { ProgressView() }
        }
    }

    // MARK: - 图标网格视图

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .compact ? 84 : 110), spacing: 16)], spacing: 20) {
                ForEach(visibleEntries) { file in
                    GridFileCell(file: file, isSelected: selectedIDs.contains(file.id))
                        .contentShape(Rectangle())
                        .onTapGesture { activate(file) }
                        .contextMenu { contextMenuItems(for: file) }
                }
            }
            .padding()
        }
        .overlay {
            if isLoading && !entries.isEmpty { ProgressView() }
        }
    }

    private var emptyView: some View {
        ContentUnavailableView {
            Label(searchText.isEmpty ? "文件夹为空" : "无搜索结果",
                  systemImage: searchText.isEmpty ? "folder" : "magnifyingglass")
        } description: {
            Text(searchText.isEmpty ? "此目录中没有内容" : "试试其他关键词")
        }
    }

    // MARK: - 工具栏（对齐系统：视图切换 / 选择 / 更多）

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if isSelecting {
                Button("取消") { resetSelection() }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if isSelecting {
                Button(allVisibleSelected ? "取消全选" : "全选") {
                    if allVisibleSelected { selectedIDs = [] }
                    else { selectedIDs = Set(visibleEntries.map(\.id)) }
                }
            } else {
                HStack(spacing: 14) {
                    Button {
                        withAnimation { model.viewMode = model.viewMode == .list ? .grid : .list }
                    } label: {
                        Image(systemName: model.viewMode == .list ? "square.grid.2x2" : "list.bullet")
                    }
                    Button {
                        isSelecting = true
                        selectedIDs = []
                    } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    moreMenu
                }
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            Menu {
                ForEach(FileSortOrder.allCases) { order in
                    Button {
                        model.sortOrder = order
                        Task { await load() }
                    } label: {
                        Label(order.rawValue, systemImage: model.sortOrder == order ? "checkmark" : "")
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
                newFolderName = ""
                pendingCreateFolder = true
            } label: {
                Label("新建文件夹", systemImage: "folder.badge.plus")
            }
            Button {
                model.showHiddenFiles.toggle()
                Task { await load() }
            } label: {
                Label(model.showHiddenFiles ? "隐藏隐藏文件" : "显示隐藏文件",
                      systemImage: model.showHiddenFiles ? "eye.slash" : "eye")
            }
            Divider()
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
            Image(systemName: "ellipsis.circle")
        }
    }

    // MARK: - 长按上下文菜单（对齐系统文件 App）

    @ViewBuilder
    private func contextMenuItems(for file: RemoteFile) -> some View {
        if !file.isDirectory {
            Button {
                Task {
                    if let url = await model.localURL(for: file, purpose: "preview") { previewURL = url }
                }
            } label: {
                Label("快速查看", systemImage: "eye")
            }
            Button {
                Task {
                    if let url = await model.localURL(for: file, purpose: "share") { shareItem = ShareItem(url: url) }
                }
            } label: {
                Label("分享", systemImage: "square.and.arrow.up")
            }
            Divider()
        }
        Button {
            infoFile = file
        } label: {
            Label("获取信息", systemImage: "info.circle")
        }
        Button {
            renameTarget(file)
        } label: {
            Label("重命名", systemImage: "pencil")
        }
        Button {
            beginTransfer(.move, files: [file])
        } label: {
            Label("移动", systemImage: "arrow.right")
        }
        Button {
            beginTransfer(.copy, files: [file])
        } label: {
            Label("复制", systemImage: "doc.on.doc")
        }
        if !file.isDirectory {
            Button {
                Task { await model.compress([file], in: node.path); await load() }
            } label: {
                Label("压缩", systemImage: "doc.zipper")
            }
        }
        Divider()
        Button(role: .destructive) {
            requestDelete([file])
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    // MARK: - 多选底部系统工具栏

    private var batchActionBar: some View {
        HStack(spacing: 4) {
            batchButton("分享", systemImage: "square.and.arrow.up") {
                Task {
                    guard let first = selectedFiles.first,
                          let url = await model.localURL(for: first, purpose: "share") else { return }
                    shareItem = ShareItem(url: url)
                }
            }
            batchButton("移动", systemImage: "arrow.right") { beginTransfer(.move, files: selectedFiles) }
            batchButton("复制", systemImage: "doc.on.doc") { beginTransfer(.copy, files: selectedFiles) }
            batchButton("压缩", systemImage: "doc.zipper") {
                Task { await model.compress(selectedFiles, in: node.path); await load(); resetSelection() }
            }
            batchButton("删除", systemImage: "trash", role: .destructive) { requestDelete(selectedFiles) }
        }
        .padding(10)
        .background(.bar)
    }

    private func batchButton(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage).font(.body)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(selectedIDs.isEmpty)
        .foregroundStyle(role == .destructive ? Color.red : Color.accentColor)
    }

    // MARK: - 操作辅助

    /// 单击：目录 push 下一级；文件进 QuickLook；多选态切换选中。
    private func activate(_ file: RemoteFile) {
        if isSelecting {
            toggleSelection(file)
        } else if file.isDirectory {
            navPath.append(FileNode(path: file.path, title: file.name))
        } else {
            Task {
                if let url = await model.localURL(for: file, purpose: "preview") { previewURL = url }
            }
        }
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
}

/// 单行文件条目：系统图标 + 名称 + 元信息；行高/间距/圆角全走系统 List 默认。
private struct FileRow: View {
    let file: RemoteFile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: FileKind(file: file).systemImage)
                .font(.title3)
                .foregroundStyle(file.isDirectory ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.body)
                    .lineLimit(1)
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var meta: String {
        if file.isDirectory { return "文件夹" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let size = formatter.string(fromByteCount: file.size)
        guard let date = file.modified else { return size }
        return "\(size) · \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

/// 图标网格单元：大图标 + 文件名，对齐系统文件 App 的图标视图。
private struct GridFileCell: View {
    let file: RemoteFile
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: FileKind(file: file).systemImage)
                .font(.system(size: 40))
                .foregroundStyle(file.isDirectory ? Color.accentColor : Color.secondary)
                .frame(height: 48)
            Text(file.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
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
