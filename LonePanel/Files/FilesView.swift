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
                        Label(L10n.t("Not Connected"), systemImage: "server.rack")
                    } description: {
                        Text(L10n.t("Add and connect a server in Settings > My Servers first"))
                    }
                } else if !model.isConnected {
                    ProgressView(L10n.t("Connecting to server..."))
                } else if !loaded {
                    ProgressView(L10n.t("Loading directory..."))
                } else if entries.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.t("Empty directory"), systemImage: "folder")
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
                    // 目录选择：有子层级时左上角提供「返回上一级」，逐级出栈；顶层才是取消。
                    ToolbarItem(placement: .topBarLeading) {
                        if pathStack.isEmpty {
                            Button(L10n.t("Cancel")) { dismiss() }
                        } else {
                            Button {
                                goBack()
                            } label: {
                                Label(L10n.t("Back"), systemImage: "chevron.left")
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            // 回传当前所在目录（栈尾或目标根），再关闭调用态。
                            target.onPick?(currentPath)
                            dismiss()
                        } label: {
                            Label(L10n.t("Choose this directory"), systemImage: "checkmark")
                                .fontWeight(.semibold)
                        }
                    }
                } else {
                    // 只读浏览：左上角有子层级时返回上一级；右上角收起。
                    if !pathStack.isEmpty {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                goBack()
                            } label: {
                                Label(L10n.t("Back"), systemImage: "chevron.left")
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        DismissChevronButton()
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

    /// 返回上一级目录：出栈并重新加载。用于左上角「返回」按钮，解决进入子目录后无法回退的问题。
    private func goBack() {
        guard !pathStack.isEmpty else { return }
        pathStack.removeLast()
        Task { await loadCurrent() }
    }

    private func loadCurrent() async {
        loaded = false
        let list = await model.listDirectory(at: currentPath)
        entries = list
        loaded = true
    }
}

// MARK: - 通用目录选择承载器（供调用方在本地层级呈现 FileCallView）

/// 把目录选择调用态以 sheet 挂在「调用方自己的视图层级」上，而不是 App 根视图。
/// 关键：当调用方本身就是一个 sheet（如新建容器表单）时，若改用根视图的全局
/// fileOpenTarget 弹 sheet，系统会因「祖先弹 sheet 时收起后代 sheet」把表单一起关掉；
/// 挂在这里则形成正确的 sheet 嵌套，选完目录只关选择器、表单原样保留。
/// 任何需要「从服务器挑一个目录」的场景都可复用：持有 item 状态 + 挂 .folderPicker。
struct FolderPickerHost: ViewModifier {
    @Binding var item: ModuleCoordinator.FileOpenTarget?

    func body(content: Content) -> some View {
        content.sheet(item: $item) { target in
            FileCallView(target: target)
                .presentationDetents([.large])
        }
    }
}

extension View {
    /// 本地承载目录选择调用态；item 由调用方持有，回传走 target.onPick。
    func folderPicker(item: Binding<ModuleCoordinator.FileOpenTarget?>) -> some View {
        modifier(FolderPickerHost(item: item))
    }
}
