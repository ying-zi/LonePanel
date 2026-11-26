import SwiftUI

/// 文件模块根视图：直接承载原生 SFTP 文件浏览器。
/// 模块私有逻辑在 Files/Core 与 Files/Browser 内，不引用其他功能模块。
struct FilesView: View {
    var body: some View {
        FileBrowserView()
    }
}

// MARK: - 文件模块「调用态」：只干活的目录浏览器

/// 供其它模块通过 ModuleCoordinator 唤起：定位到指定服务器目录、可逐层浏览、下拉即走。
/// 两种模式：
/// - 只读浏览（默认）：看完「完成」即走，如容器卷挂载点浏览；
/// - 目录选择（target.pickDirectory）：可逐层进入，点「选择此目录」把当前路径回传给调用方，
///   供容器挂载目录、网站备份、数据库备份等需要"从服务器挑一个目录"的场景复用。
/// 与入口态的严格隔离：
/// - 用独立的 FileBrowserModel 实例，绝不触碰 shared（不污染单例导航栈 / 默认目录）；
/// - 不显示"设为默认访问目录"等任何写用户偏好的入口；
/// - 不引用设置入口（调用态无齿轮）；所有视图偏好只读当前值，不主动改写。
struct FileCallView: View {
    let target: ModuleCoordinator.FileOpenTarget
    @Environment(\.dismiss) private var dismiss
    /// 独立模型实例：生命周期跟随本视图，关闭即释放。
    @StateObject private var model = FileBrowserModel()
    @State private var pathStack: [FileNode] = []
    @State private var entries: [RemoteFile] = []
    @State private var loaded = false

    /// 当前所在目录：栈尾或目标根。
    private var currentPath: String { pathStack.last?.path ?? target.path }
    private var currentTitle: String { pathStack.last?.title ?? (target.path as NSString).lastPathComponent }

    var body: some View {
        NavigationStack {
            Group {
                if !model.hasConfiguredServer {
                    ContentUnavailableView {
                        Label("未连接服务器", systemImage: "server.rack")
                    } description: {
                        Text("请先在「设置 → 我的服务器」添加并连接一台服务器")
                    }
                } else if !model.isConnected {
                    ProgressView("正在连接服务器…")
                } else if !loaded {
                    ProgressView("正在读取目录…")
                } else if entries.isEmpty {
                    ContentUnavailableView {
                        Label("空目录", systemImage: "folder")
                    } description: {
                        Text(currentPath)
                            .font(.caption.monospaced())
                    }
                } else {
                    List(entries) { file in
                        HStack(spacing: 10) {
                            Image(systemName: FileKind(file: file).systemImage)
                                .foregroundStyle(FileKind(file: file).tint)
                            Text(file.name)
                                .lineLimit(1)
                            if file.isDirectory {
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if file.isDirectory { enter(file) }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable { await loadCurrent() }
                }
            }
            .navigationTitle(currentTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if target.pickDirectory {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            // 回传当前所在目录（栈尾或目标根），再关闭调用态。
                            target.onPick?(currentPath)
                            dismiss()
                        } label: {
                            Label("选择此目录", systemImage: "checkmark")
                                .fontWeight(.semibold)
                        }
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { dismiss() }
                    }
                }
            }
        }
        .task {
            await model.connectIfNeeded()
            guard model.isConnected else { return }
            await loadCurrent()
        }
    }

    private func enter(_ file: RemoteFile) {
        let name = (currentPath as NSString).appendingPathComponent(file.name)
        pathStack.append(FileNode(path: name, title: file.name))
        Task { await loadCurrent() }
    }

    private func loadCurrent() async {
        loaded = false
        let list = await model.listDirectory(at: currentPath)
        entries = list
        loaded = true
    }
}
