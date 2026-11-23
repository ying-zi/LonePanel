import SwiftUI
import QuickLook

/// 对齐 iOS 26/27 系统「文件」App 的浏览器：
/// - 逐层 push 导航，左上角沿用系统原生返回箭头（顶层不显示、子层级显示）；
/// - 标题下拉为系统原生 Menu，列出从根目录到当前的层级，点击任一极跳转；
/// - 列表 / 图标网格两种视图，系统默认行样式，每一个条目整行可点；
/// - 长按上下文菜单、左滑操作、多选态浮动玻璃工具条；
/// - 单击文件走系统 QuickLook，分享走系统分享面板；拷贝→粘贴走共享剪贴板。
struct FileBrowserView: View {
    @StateObject private var model = FileBrowserModel()
    @ObservedObject private var session = ServerSession.shared

    /// NavigationStack 导航栈：根不进 path；回根即清空。系统原生返回由 NavigationStack 管理。
    @State private var navPath: [FileNode] = []
    @State private var previewURL: URL?
    @State private var shareItem: ShareItem?

    var body: some View {
        Group {
            if model.isConnected {
                NavigationStack(path: $navPath) {
                    DirectoryPage(
                        model: model,
                        node: FileNode(path: model.entryPath, title: model.serverName),
                        previewURL: $previewURL,
                        shareItem: $shareItem,
                        navPath: $navPath
                    )
                    .navigationDestination(for: FileNode.self) { node in
                        DirectoryPage(
                            model: model,
                            node: node,
                            previewURL: $previewURL,
                            shareItem: $shareItem,
                            navPath: $navPath
                        )
                    }
                }
            } else {
                disconnectedView
            }
        }
        .task {
            await model.connectIfNeeded()
            if model.isConnected { resetToRoot() }
        }
        .onChange(of: session.currentServer?.id) { _, _ in
            Task { await model.reconnect(); resetToRoot() }
        }
        // 单击当前文件 Tab：回默认目录入口（清导航栈、清剪贴板）。
        .onReceive(TabNavigationCenter.shared.$resetRequest) { request in
            guard let request, request.tabID == "files" else { return }
            resetToRoot()
        }
        .quickLookPreview($previewURL)
        .sheet(item: $shareItem) { ActivityShareSheet(items: $0.urls) }
        .alert("操作提示", isPresented: errorBinding) {
            Button("好", role: .cancel) { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
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

    private func resetToRoot() {
        navPath = []
        model.clearClipboard()
        previewURL = nil
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
    @State private var searchText = ""
    @State private var isSearching = false
    @FocusState private var searchFocused: Bool
    @State private var isSelecting = false
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

    /// 是否处于根页（navPath 为空且当前节点是入口）。根页不显示系统返回箭头，子层级显示。
    private var isRootPage: Bool { navPath.isEmpty }

    var body: some View {
        pageContent
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await load() }
            .task { await load() }
            .toolbar { toolbarContent }
            // 多选态隐藏系统返回键（左上角改放"全选"）；正常态保留系统原生返回箭头。
            .navigationBarBackButtonHidden(isSelecting)
            .safeAreaInset(edge: .bottom) { if isSelecting { batchActionBar } }
            .background(dialogHost)
    }

    /// 退出搜索：清空关键词并收起标题位的输入框。
    private func closeSearch() {
        searchText = ""
        searchFocused = false
        isSearching = false
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
        entries = await model.listDirectory(at: node.path)
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
                    FileRow(file: file, isSelected: selectedIDs.contains(file.id), showsCheckmark: true)
                }
                .buttonStyle(.plain)
            } else if file.isDirectory {
                NavigationLink(value: FileNode(path: file.path, title: file.name)) {
                    FileRow(file: file)
                }
            } else {
                Button { quickLook(file) } label: { FileRow(file: file) }
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
                    GridFileCell(file: file, isSelected: selectedIDs.contains(file.id))
                }
                .buttonStyle(.plain)
            } else if file.isDirectory {
                NavigationLink(value: FileNode(path: file.path, title: file.name)) {
                    GridFileCell(file: file)
                }
                .buttonStyle(.plain)
            } else {
                Button { quickLook(file) } label: { GridFileCell(file: file) }
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
            if isSelecting {
                Button(allVisibleSelected ? "取消全选" : "全选") {
                    if allVisibleSelected { selectedIDs = [] }
                    else { selectedIDs = Set(visibleEntries.map(\.id)) }
                }
            }
            // 非多选态不放置任何 leading item，让系统原生返回箭头显示（根页自动隐藏）。
        }
        ToolbarItem(placement: .principal) {
            if isSelecting {
                Text("\(selectedIDs.count) 项").font(.headline)
            } else if isSearching {
                searchField
            } else {
                titleMenu
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if isSelecting {
                Button { resetSelection() } label: {
                    Image(systemName: "checkmark.circle.fill").font(.title3)
                }
            } else if isSearching {
                Button("取消") { closeSearch() }
            } else {
                HStack(spacing: 14) {
                    Button { isSearching = true; searchFocused = true } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    moreMenu
                }
            }
        }
    }

    /// 搜索态标题位输入框：替代原标题 Menu，自动聚焦，带一键清空。
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("搜索", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.7), in: Capsule())
        .frame(width: sizeClass == .compact ? 220 : 320)
    }

    /// 标题下拉：与右上 ⋯ 一致的系统原生 Menu，列出从根目录到当前的位置层级。
    /// navPath 为根之后的逐级节点，故完整层级 = [根] + navPath。
    private var titleMenu: some View {
        Menu {
            ForEach(Array(levelNodes.enumerated()), id: \.offset) { idx, level in
                Button {
                    jumpToLevel(idx)
                } label: {
                    Label(level.title, systemImage: idx == currentLevel ? "checkmark" : (idx == 0 ? "folder" : "folder.fill"))
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

    /// 从根到当前的完整层级节点（根 + navPath 中已 push 的各层）。
    private var levelNodes: [FileNode] {
        [FileNode(path: model.entryPath, title: model.serverName)] + navPath
    }

    private var currentLevel: Int { navPath.count }

    /// 跳到指定层级：截断 navPath 到该深度。idx=0（根目录）即清空导航栈。
    private func jumpToLevel(_ idx: Int) {
        guard idx < navPath.count else { return }
        navPath = Array(navPath.prefix(idx))
        model.clearClipboard()
    }

    private var moreMenu: some View {
        Menu {
            Button {
                isSelecting = true
                selectedIDs = []
            } label: {
                Label("选择", systemImage: "checkmark.circle")
            }
            Button {
                newFolderName = ""
                pendingCreateFolder = true
            } label: {
                Label("新建文件夹", systemImage: "folder.badge.plus")
            }
            Button {
                newFileName = ""
                pendingCreateFile = true
            } label: {
                Label("新建文件", systemImage: "doc.badge.plus")
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
            Image(systemName: "ellipsis.circle")
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
            // 共享仅对选中的文件有效（目录无法作为单文件分享）。
            if selectedFiles.contains(where: { !$0.isDirectory }) {
                batchIcon("square.and.arrow.up", title: "共享") { shareSelected() }
            }
            batchIcon("arrow.right", title: "移动") { beginTransfer(.move, files: selectedFiles) }
            batchIcon("doc.on.doc", title: "拷贝") { copySelected() }
            if !model.clipboard.isEmpty {
                batchIcon("doc.on.clipboard", title: "粘贴") {
                    Task { await pasteHere() }
                }
            }
            batchIcon("trash", title: "删除", role: .destructive) { requestDelete(selectedFiles) }
            Menu {
                Button(allVisibleSelected ? "取消全选" : "全选") {
                    if allVisibleSelected { selectedIDs = [] }
                    else { selectedIDs = Set(visibleEntries.map(\.id)) }
                }
                Button("新建文件夹") { newFolderName = ""; pendingCreateFolder = true }
                Button("获取信息") {
                    if let first = selectedFiles.first { infoFile = first }
                }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "ellipsis.circle").font(.title3)
                    Text("更多").font(.caption2)
                }
                .frame(maxWidth: .infinity, minHeight: 52)
                .contentShape(Rectangle())
            }
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
}

/// 单行文件条目：系统图标 + 名称 + 元信息；撑满整行使整行都可点。
private struct FileRow: View {
    let file: RemoteFile
    var isSelected = false
    var showsCheckmark = false

    var body: some View {
        HStack(spacing: 12) {
            if showsCheckmark {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            Image(systemName: FileKind(file: file).systemImage)
                .font(.title3)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var meta: String {
        let date = file.modified?.formatted(date: .abbreviated, time: .omitted) ?? ""
        if file.isDirectory { return date.isEmpty ? "文件夹" : date }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let size = formatter.string(fromByteCount: file.size)
        return date.isEmpty ? size : "\(date) · \(size)"
    }
}

/// 图标网格单元：大图标 + 文件名，撑满整格可点。
private struct GridFileCell: View {
    let file: RemoteFile
    var isSelected = false

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
