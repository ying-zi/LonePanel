import SwiftUI

/// 参照系统「文件」App 的原生浏览器：路径摘要浮层、原生列表、滑动操作、
/// 多选批量、原生预览与详情。行高/间距/圆角/分组全部使用系统 List 默认值。
struct FileBrowserView: View {
    @StateObject private var model = FileBrowserModel()
    @ObservedObject private var session = ServerSession.shared
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// 详情页以 push 呈现，子层级左上自带系统返回箭头。
    @State private var detailPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $detailPath) {
            stackContent
        }
        .task { await model.connectIfNeeded() }
        .onChange(of: session.currentServer?.id) { _, _ in
            detailPath = NavigationPath()
            Task { await model.connectIfNeeded(force: true) }
        }
        // 单击当前文件 Tab：回默认目录入口。
        .onReceive(TabNavigationCenter.shared.$resetRequest) { request in
            guard let request, request.tabID == "files" else { return }
            detailPath = NavigationPath()
            model.returnToDefaultEntry()
        }
        .alert("操作提示", isPresented: errorBinding) {
            Button("好", role: .cancel) { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("新建文件夹", isPresented: $model.pendingCreateFolder) {
            TextField("文件夹名称", text: $model.newFolderName)
            Button("取消", role: .cancel) { model.newFolderName = "" }
            Button("创建") { Task { await model.createFolder() } }
        }
        .alert("重命名", isPresented: renameBinding) {
            TextField("名称", text: $model.renameText)
            Button("取消", role: .cancel) { model.renaming = nil }
            Button("保存") { Task { await model.confirmRename() } }
        }
        .confirmationDialog(
            "删除 \(model.deleting.count) 个项目？",
            isPresented: deleteBinding,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { Task { await model.confirmDelete() } }
            Button("取消", role: .cancel) { model.deleting = [] }
        }
        .confirmationDialog(
            "危险路径",
            isPresented: $model.showDangerConfirm,
            titleVisibility: .visible
        ) {
            Button("我确认，继续删除", role: .destructive) { model.acceptDangerAndContinueDelete() }
            Button("取消", role: .cancel) { model.deleting = [] }
        } message: {
            Text("所选内容位于系统关键目录（如 /etc、/usr）。删除可能导致系统异常，请务必确认你清楚后果。")
        }
        .sheet(isPresented: targetPickerBinding) {
            TargetDirectorySheet(model: model)
        }
    }

    /// 导航栈内容单独拆分，避免 body 表达式过重导致类型检查超时。
    @ViewBuilder
    private var stackContent: some View {
        Group {
            if !model.isConnected {
                disconnectedView
            } else {
                directoryList
            }
        }
        .navigationDestination(for: RemoteFile.self) { file in
            detailDestination(for: file)
        }
        .overlay {
            if model.showPathMenu {
                PathMenuOverlay(model: model)
            }
        }
    }

    private func detailDestination(for file: RemoteFile) -> some View {
        FileDetailView(
            model: model,
            file: file,
            onRename: { target in
                model.renaming = target
                model.renameText = target.name
            },
            onMove: { target in
                model.beginTransfer(.move, files: [target])
            },
            onDelete: { target in
                detailPath = NavigationPath()
                model.requestDelete([target])
            }
        )
    }

    private var disconnectedView: some View {
        ContentUnavailableView {
            Label("未连接服务器", systemImage: "server.rack")
        } description: {
            Text("请在「设置 → 我的服务器」中添加并连接一台服务器，然后重试")
        } actions: {
            Button("重新连接") { Task { await model.connectIfNeeded(force: true) } }
                .buttonStyle(.borderedProminent)
        }
    }

    private var directoryList: some View {
        List {
            if model.isLoading && model.visibleEntries.isEmpty {
                ProgressView("加载中…")
            } else if model.visibleEntries.isEmpty {
                ContentUnavailableView {
                    Label(model.searchText.isEmpty ? "文件夹为空" : "无搜索结果",
                          systemImage: model.searchText.isEmpty ? "folder" : "magnifyingglass")
                } description: {
                    Text(model.searchText.isEmpty ? "此目录中没有内容" : "试试其他关键词")
                }
            } else {
                ForEach(model.visibleEntries) { file in
                    FileRow(file: file, isSelected: model.selectedIDs.contains(file.id))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if model.isSelecting {
                                model.toggleSelection(file)
                            } else if file.isDirectory {
                                model.enter(file)
                            } else {
                                detailPath.append(file)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !model.isSelecting {
                                Button {
                                    model.beginTransfer(.move, files: [file])
                                } label: {
                                    Label("移动", systemImage: "arrow.right")
                                }
                                .tint(.blue)

                                Button {
                                    model.renaming = file
                                    model.renameText = file.name
                                } label: {
                                    Label("重命名", systemImage: "pencil")
                                }
                                .tint(.orange)

                                Button(role: .destructive) {
                                    model.requestDelete([file])
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $model.searchText, prompt: "搜索文件")
        .refreshable { await model.loadCurrent() }
        .overlay {
            if model.isLoading && !model.visibleEntries.isEmpty {
                ProgressView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) {
            if model.isSelecting { batchActionBar }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if model.isSelecting {
                Button("取消") { model.resetSelection() }
            } else {
                pathSummaryButton
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if model.isSelecting {
                Button(model.allVisibleSelected ? "取消全选" : "全选") {
                    if model.allVisibleSelected { model.selectedIDs = [] } else { model.selectAll() }
                }
            } else {
                trailingMenu
            }
        }
    }

    /// 左上路径摘要，约占顶部宽度 60%，点击展开层级浮层。
    private var pathSummaryButton: some View {
        Button {
            withAnimation { model.showPathMenu.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                Text(model.pathSummary)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: sizeClass == .compact ? 220 : 320, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    /// 右侧操作区保留足够宽度；窄屏时次级操作收进右上「⋯」。
    private var trailingMenu: some View {
        HStack(spacing: 12) {
            Button {
                model.isSelecting = true
            } label: {
                Image(systemName: "checkmark.circle")
            }
            Menu {
                Button {
                    model.newFolderName = ""
                    model.pendingCreateFolder = true
                } label: {
                    Label("新建文件夹", systemImage: "folder.badge.plus")
                }
                Button {
                    model.showHiddenFiles.toggle()
                } label: {
                    Label(model.showHiddenFiles ? "隐藏隐藏文件" : "显示隐藏文件",
                          systemImage: model.showHiddenFiles ? "eye.slash" : "eye")
                }
                Button {
                    model.setAsDefaultDirectory()
                } label: {
                    Label("设为默认访问目录", systemImage: "folder.badge.gearshape")
                }
                Button {
                    Task { await model.connectIfNeeded(force: true) }
                } label: {
                    Label("重新连接", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .frame(minWidth: sizeClass == .compact ? 90 : 140, alignment: .trailing)
    }

    /// 多选态底部批量操作条：移动、复制、删除、压缩。
    private var batchActionBar: some View {
        HStack(spacing: 4) {
            batchButton("移动", systemImage: "arrow.right") {
                model.beginTransfer(.move, files: model.selectedFiles)
            }
            batchButton("复制", systemImage: "doc.on.doc") {
                model.beginTransfer(.copy, files: model.selectedFiles)
            }
            batchButton("删除", systemImage: "trash", role: .destructive) {
                model.requestDelete(model.selectedFiles)
            }
            batchButton("压缩", systemImage: "doc.zipper") {
                Task { await model.compressSelected() }
            }
        }
        .padding(8)
        .background(.ultraThinMaterial)
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
        .disabled(model.selectedIDs.isEmpty)
        .foregroundStyle(role == .destructive ? Color.red : Color.accentColor)
    }

    // MARK: - 绑定辅助

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.dismissError() } })
    }
    private var renameBinding: Binding<Bool> {
        Binding(get: { model.renaming != nil }, set: { if !$0 { model.renaming = nil } })
    }
    private var deleteBinding: Binding<Bool> {
        Binding(get: { !model.deleting.isEmpty && !model.showDangerConfirm },
                set: { if !$0 { model.deleting = [] } })
    }
    private var targetPickerBinding: Binding<Bool> {
        Binding(
            get: { model.targetPickerOperation != nil },
            set: { if !$0 { model.targetPickerOperation = nil; model.targetPickerFiles = [] } }
        )
    }
}

/// 纵向路径层级浮层：首行"根目录"，逐级列出，当前行高亮；点遮罩或再点摘要收起。
private struct PathMenuOverlay: View {
    @ObservedObject var model: FileBrowserModel

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // 遮罩：点击空白处收起。
                Color.black.opacity(0.25)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation { model.showPathMenu = false }
                    }

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.pathSegments) { segment in
                        Button {
                            Task { await model.navigate(to: segment.path) }
                            withAnimation { model.showPathMenu = false }
                        } label: {
                            HStack {
                                Image(systemName: "folder")
                                    .foregroundStyle(segment.path == model.currentPath ? Color.accentColor : Color.secondary)
                                Text(segment.name)
                                    .foregroundStyle(segment.path == model.currentPath ? Color.accentColor : Color.primary)
                                Spacer()
                                if segment.path == model.currentPath {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if segment.path != model.pathSegments.last?.path {
                            Divider().padding(.leading, 40)
                        }
                    }
                }
                .frame(width: min(260, geo.size.width - 32))
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
                }
                .shadow(radius: 12, y: 6)
                .padding(.leading, 12)
                .padding(.top, geo.safeAreaInsets.top + 4)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// 目标目录选择器：移动/复制时选择目标目录，可逐级进入、返回上级。
private struct TargetDirectorySheet: View {
    @ObservedObject var model: FileBrowserModel

    var body: some View {
        NavigationStack {
            List {
                Button {
                    model.goUpTarget()
                } label: {
                    Label("上级目录", systemImage: "arrow.up.folder")
                }
                .disabled(model.targetPath == "/")

                if model.targetIsLoading {
                    ProgressView("加载中…")
                } else {
                    ForEach(model.targetEntries) { dir in
                        Button {
                            model.enterTarget(dir)
                        } label: {
                            Label(dir.name, systemImage: "folder.fill")
                        }
                    }
                }
            }
            .navigationTitle("选择目标目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        model.targetPickerOperation = nil
                        model.targetPickerFiles = []
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        Task { await model.confirmTransfer() }
                    }
                    .fontWeight(.semibold)
                }
            }
            .task { await model.loadTargetDirectory() }
        }
    }
}

/// 单行文件条目：系统图标 + 名称 + 元信息，行样式走系统默认。
private struct FileRow: View {
    let file: RemoteFile
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbolName)
                .font(.title3)
                .foregroundStyle(file.isDirectory ? Color.blue : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(.body)
                    .lineLimit(1)
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if isSelected {
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private var symbolName: String {
        if file.isDirectory { return "folder.fill" }
        if file.isSymlink { return "arrow.turn.down.right" }
        let ext = (file.name as NSString).pathExtension.lowercased()
        let map: [String: String] = [
            "txt": "doc.text", "md": "doc.text", "log": "doc.text",
            "json": "curlybraces", "yml": "curlybraces", "yaml": "curlybraces",
            "sh": "terminal", "py": "chevron.left.forwardslash.chevron.right",
            "jpg": "photo", "jpeg": "photo", "png": "photo", "gif": "photo",
            "pdf": "doc.richtext", "zip": "doc.zipper", "tar": "doc.zipper", "gz": "doc.zipper"
        ]
        return map[ext] ?? "doc"
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
