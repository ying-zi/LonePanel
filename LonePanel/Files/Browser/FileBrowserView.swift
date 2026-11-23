import SwiftUI
import QuickLook

/// 对齐 iOS 26/27 系统「文件」App 的浏览器：
/// - 逐层 push 导航，顶部为「返回/前进」胶囊，标题带下拉箭头可展开位置层级；
/// - 列表 / 图标网格两种视图，系统默认行样式，每一个条目整行可点；
/// - 长按上下文菜单（顶部快捷三连）、左滑操作、多选态浮动玻璃工具条；
/// - 单击文件走系统 QuickLook，分享走系统分享面板。
struct FileBrowserView: View {
    @StateObject private var model = FileBrowserModel()
    @StateObject private var history = NavigationHistory()
    @ObservedObject private var session = ServerSession.shared

    @State private var previewURL: URL?
    @State private var shareItem: ShareItem?

    /// NavigationStack 的 path 由历史游标派生：根不进 path，返回/前进即游标移动。
    private var navPath: Binding<[FileNode]> {
        Binding(get: { history.path }, set: { history.sync(path: $0) })
    }

    var body: some View {
        Group {
            if model.isConnected {
                NavigationStack(path: navPath) {
                    DirectoryPage(
                        model: model,
                        node: FileNode(path: model.entryPath, title: model.serverName)
                    )
                    .navigationDestination(for: FileNode.self) { node in
                        DirectoryPage(model: model, node: node)
                    }
                }
            } else {
                disconnectedView
            }
        }
        .environmentObject(history)
        .task {
            await model.connectIfNeeded()
            if model.isConnected { resetToRoot() }
        }
        .onChange(of: session.currentServer?.id) { _, _ in
            Task { await model.reconnect(); resetToRoot() }
        }
        // 单击当前文件 Tab：回默认目录入口（清历史到根）。
        .onReceive(TabNavigationCenter.shared.$resetRequest) { request in
            guard let request, request.tabID == "files" else { return }
            resetToRoot()
        }
        .quickLookPreview($previewURL)
        .sheet(item: $shareItem) { ActivityShareSheet(item: $0.url) }
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
        history.reset(to: FileNode(path: model.entryPath, title: model.serverName))
        previewURL = nil
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.dismissError() } })
    }
}

/// 目录浏览历史：nodes[0] 为根，index 为当前层级。系统 NavigationStack 只有返回，
/// 前进/后退胶囊由此游标驱动（系统无原生前进控件，属"系统没有的才自己写"）。
final class NavigationHistory: ObservableObject {
    @Published private(set) var nodes: [FileNode] = []
    @Published private(set) var index: Int = 0

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < nodes.count - 1 }

    /// 传给 NavigationStack 的 path：不含根，长度等于当前深度。
    var path: [FileNode] {
        guard index > 0, nodes.count > 1 else { return [] }
        return Array(nodes.dropFirst().prefix(index))
    }

    func reset(to root: FileNode) {
        nodes = [root]
        index = 0
    }

    /// 系统 push/pop 触发 path 变化时同步历史；push 新节点会截断此前的前进历史。
    func sync(path newPath: [FileNode]) {
        if newPath.count < index {
            index = newPath.count
        } else if newPath.count > index {
            if nodes.count > index + 1 {
                nodes = Array(nodes.prefix(index + 1))
            }
            for node in newPath.dropFirst(index) {
                nodes.append(node)
            }
            index = newPath.count
        }
    }

    func goBack() { if index > 0 { index -= 1 } }
    func goForward() { if index < nodes.count - 1 { index += 1 } }
    func jump(to target: Int) {
        guard target >= 0, target < nodes.count else { return }
        index = target
    }
}

/// 单一目录层级页面。自己的条目、搜索、多选与弹窗状态互不干扰，返回上层天然保留。
private struct DirectoryPage: View {
    @ObservedObject var model: FileBrowserModel
    @EnvironmentObject private var history: NavigationHistory
    let node: FileNode

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var entries: [RemoteFile] = []
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var isSelecting = false
    @State private var selectedIDs: Set<RemoteFile.ID> = []
    @State private var showPathMenu = false

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

    var body: some View {
        pageContent
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索")
            .refreshable { await load() }
            .task { await load() }
            .toolbar { toolbarContent }
            .navigationBarBackButtonHidden(true)
            .safeAreaInset(edge: .bottom) { if isSelecting { batchActionBar } }
            .overlay { pathMenuOverlay }
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

    // MARK: - 顶部工具栏（返回/前进胶囊 · 标题下拉 · ⋯）

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if isSelecting {
                Button(allVisibleSelected ? "取消全选" : "全选") {
                    if allVisibleSelected { selectedIDs = [] }
                    else { selectedIDs = Set(visibleEntries.map(\.id)) }
                }
            } else {
                navArrows
            }
        }
        ToolbarItem(placement: .principal) {
            if isSelecting {
                Text("\(selectedIDs.count) 项").font(.headline)
            } else {
                titleMenu
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if isSelecting {
                Button { resetSelection() } label: {
                    Image(systemName: "checkmark.circle.fill").font(.title3)
                }
            } else {
                moreMenu
            }
        }
    }

    /// 返回/前进胶囊（系统无原生前进，自己维护历史游标）。
    private var navArrows: some View {
        HStack(spacing: 0) {
            Button { history.goBack() } label: {
                Image(systemName: "chevron.left").font(.body.weight(.semibold))
            }
            .disabled(!history.canGoBack)
            Divider().frame(height: 14)
            Button { history.goForward() } label: {
                Image(systemName: "chevron.right").font(.body.weight(.semibold))
            }
            .disabled(!history.canGoForward)
        }
        .buttonStyle(.plain)
        .frame(width: 68, height: 30)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }

    /// 标题带下拉箭头，展开位置层级浮层。
    private var titleMenu: some View {
        Button { withAnimation { showPathMenu.toggle() } } label: {
            HStack(spacing: 4) {
                Text(node.title).font(.headline).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }

    /// 当前可跳转的层级（根到当前），供标题下拉浮层列出。
    private var visibleLevels: [FileNode] {
        Array(history.nodes.prefix(history.index + 1))
    }

    /// 标题下方展开的纵向位置层级：首行"根目录"，逐级列出，当前高亮，点击跳转。
    @ViewBuilder
    private var pathMenuOverlay: some View {
        if showPathMenu {
            ZStack(alignment: .top) {
                Color.black.opacity(0.2)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation { showPathMenu = false } }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visibleLevels.enumerated()), id: \.offset) { idx, level in
                        Button {
                            history.jump(to: idx)
                            withAnimation { showPathMenu = false }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: idx == history.index ? "checkmark" : (idx == 0 ? "folder" : "folder.fill"))
                                    .foregroundStyle(idx == history.index ? Color.accentColor : Color.secondary)
                                Text(idx == 0 ? "根目录" : level.title)
                                    .foregroundStyle(idx == history.index ? Color.accentColor : Color.primary)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if idx != visibleLevels.count - 1 {
                            Divider().padding(.leading, 40)
                        }
                    }
                }
                .frame(width: 260)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
                }
                .shadow(radius: 12, y: 6)
                .padding(.top, 46)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
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
            Button { beginTransfer(.copy, files: [file]) } label: {
                Label("拷贝", systemImage: "doc.on.doc")
            }
            Button { beginTransfer(.move, files: [file]) } label: {
                Label("移动", systemImage: "arrow.right")
            }
            Button { share(file) } label: {
                Label("共享", systemImage: "square.and.arrow.up")
            }
        }
        Divider()
        if !file.isDirectory {
            Button { quickLook(file) } label: { Label("快速查看", systemImage: "eye") }
        }
        Button { infoFile = file } label: { Label("获取信息", systemImage: "info.circle") }
        Button { renameTarget(file) } label: { Label("重命名", systemImage: "pencil") }
        if !file.isDirectory {
            Button {
                Task { await model.compress([file], in: node.path); await load() }
            } label: {
                Label("压缩", systemImage: "doc.zipper")
            }
        }
        Divider()
        Button(role: .destructive) { requestDelete([file]) } label: {
            Label("删除", systemImage: "trash")
        }
    }

    // MARK: - 多选底部浮动玻璃工具条

    private var batchActionBar: some View {
        HStack(spacing: 4) {
            batchIcon("square.and.arrow.up") { shareFirstSelected() }
            batchIcon("arrow.right") { beginTransfer(.move, files: selectedFiles) }
            batchIcon("doc.on.doc") { beginTransfer(.copy, files: selectedFiles) }
            batchIcon("doc.zipper") {
                Task { await model.compress(selectedFiles, in: node.path); await load(); resetSelection() }
            }
            batchIcon("trash", role: .destructive) { requestDelete(selectedFiles) }
            Divider().frame(height: 22)
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
                Image(systemName: "ellipsis.circle").font(.body)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
        }
        .shadow(radius: 12, y: 5)
        .disabled(selectedIDs.isEmpty)
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    private func batchIcon(_ name: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Image(systemName: name).font(.body)
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

    private func shareFirstSelected() {
        guard let first = selectedFiles.first else { return }
        share(first)
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
