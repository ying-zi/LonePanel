import SwiftUI
import QuickLook

/// 参照系统「文件」App 的原生浏览器：层级导航、搜索、刷新、滑动操作、原生预览。
struct FileBrowserView: View {
    @StateObject private var model = FileBrowserModel()
    @ObservedObject private var session = ServerSession.shared

    var body: some View {
        NavigationStack {
            Group {
                if !model.isConnected {
                    disconnectedView
                } else {
                    DirectoryList(model: model, title: model.currentDisplayName, isRoot: true)
                }
            }
            .navigationDestination(for: RemoteFile.self) { folder in
                DirectoryList(model: model, title: folder.name, isRoot: false)
                    .navigationTitle(folder.name)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task { await model.connectIfNeeded() }
        .onChange(of: session.currentServer?.id) { _ in
            Task { await model.connectIfNeeded(force: true) }
        }
        .alert("操作提示", isPresented: errorBinding) {
            Button("好", role: .cancel) { model.errorMessage = nil }
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
            "删除「\(model.deleting?.name ?? "")」？",
            isPresented: deleteBinding,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { Task { await model.confirmDelete() } }
            Button("取消", role: .cancel) { model.deleting = nil }
        }
        .quickLookPreview($model.previewURL)
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

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
    private var renameBinding: Binding<Bool> {
        Binding(get: { model.renaming != nil }, set: { if !$0 { model.renaming = nil } })
    }
    private var deleteBinding: Binding<Bool> {
        Binding(get: { model.deleting != nil }, set: { if !$0 { model.deleting = nil } })
    }
}

/// 单个目录的列表页：根页面与子目录页面共用同一套原生交互。
struct DirectoryList: View {
    @ObservedObject var model: FileBrowserModel
    let title: String
    let isRoot: Bool

    var body: some View {
        List {
            if model.isLoading && model.entries.isEmpty {
                ProgressView("加载中…")
            } else if model.filteredEntries.isEmpty {
                ContentUnavailableView {
                    Label(model.searchText.isEmpty ? "文件夹为空" : "无搜索结果",
                          systemImage: model.searchText.isEmpty ? "folder" : "magnifyingglass")
                } description: {
                    Text(model.searchText.isEmpty ? "此目录中没有内容" : "试试其他关键词")
                }
            } else {
                ForEach(model.filteredEntries) { file in
                    FileRow(file: file)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if file.isDirectory {
                                model.enter(file)
                            } else {
                                Task { await model.preview(file) }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                model.deleting = file
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button {
                                model.renaming = file
                                model.renameText = file.name
                            } label: {
                                Label("重命名", systemImage: "pencil")
                            }
                            .tint(.orange)
                        }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(isRoot ? .large : .inline)
        .searchable(text: $model.searchText, prompt: "搜索文件")
        .refreshable { await model.loadCurrent() }
        .overlay {
            if model.isLoading && !model.entries.isEmpty {
                ProgressView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        model.newFolderName = ""
                        model.pendingCreateFolder = true
                    } label: {
                        Label("新建文件夹", systemImage: "folder.badge.plus")
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
        }
    }
}

/// 单行文件条目：系统图标 + 名称 + 元信息。
private struct FileRow: View {
    let file: RemoteFile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbolName)
                .font(.title3)
                .foregroundStyle(file.isDirectory ? Color.blue : Color.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(.body)
                    .lineLimit(1)
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
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
