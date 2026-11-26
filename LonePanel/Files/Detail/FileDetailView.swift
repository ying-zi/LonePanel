import SwiftUI
import UIKit

/// 系统风格的「获取信息」面板：对齐 iOS 26 文件 App 的 Info 页面，
/// 顶部大图标 + 文件名，下面用原生 List/LabeledContent 列出属性。
/// 单击文件本身改为系统 QuickLook 预览，不在这里做自定义文本编辑/编码切换。
struct FileInfoSheet: View {
    let file: RemoteFile
    let model: FileBrowserModel
    @Environment(\.dismiss) private var dismiss
    /// 文件夹的真实统计（SSH du/find 获取）；nil 表示未加载/不支持/失败。
    @State private var folderStats: FolderStats?
    @State private var statsLoading = false
    /// 属主的可读名称（用户 · 组），由 /etc/passwd 映射解析后回填。
    @State private var ownerName: String = L10n.t("Unknown User · Unknown Group")

    var body: some View {
        NavigationStack {
            List {
                headerSection
                attributesSection
                if file.isDirectory { folderStatsSection }
                locationSection
            }
            .navigationTitle(L10n.t("Info"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Done")) { dismiss() }
                }
            }
            .task {
                // 属主名称与文件夹扫描相互独立：文件类型只需前者，文件夹两者都要。
                await model.loadOwnerNamesIfNeeded()
                ownerName = model.ownerDisplay(uid: file.uid, gid: file.gid)
                guard file.isDirectory else { return }
                await scanFolder()
            }
        }
    }

    private var headerSection: some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: FileKind(file: file).systemImage)
                    .font(.system(size: 56))
                    .foregroundStyle(file.isDirectory ? Color.accentColor : Color.secondary)
                Text(file.name)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private var attributesSection: some View {
        Section(L10n.t("Attributes")) {
            LabeledContent(L10n.t("Kind"), value: kindLabel)
            // 文件夹的 STAT size 无意义（见 folderStatsSection），只给文件显示大小。
            if !file.isDirectory {
                LabeledContent(L10n.t("Size"), value: byteSize)
            }
            if let date = file.modified {
                LabeledContent(L10n.t("Date Modified"), value: date.formatted(date: .abbreviated, time: .shortened))
            }
            LabeledContent(L10n.t("Permissions"), value: file.permissionText)
            LabeledContent(L10n.t("Owner"), value: ownerName)
        }
    }

    /// 文件夹真实统计：磁盘占用 / 文件数 / 子目录数。
    /// SFTP STAT 的目录 size 只是一个固定值（通常 4096），不代表实际占用，
    /// 因此这里展示通过 SSH du/find 命令测得的数据；冷磁盘首次扫描较慢，
    /// 加载中显示转圈，失败给出「扫描失败」与重试按钮，由用户决定何时再扫。
    @ViewBuilder
    private var folderStatsSection: some View {
        Section(L10n.t("Contents")) {
            if statsLoading {
                HStack {
                    Text(L10n.t("Scanning folder…"))
                    Spacer()
                    ProgressView()
                }
            } else if let stats = folderStats {
                LabeledContent(L10n.t("Disk Usage"), value: FileBrowserModel.sizeText(stats.sizeBytes))
                LabeledContent(L10n.t("Files"), value: L10n.f("%@ items", String(describing: (stats.fileCount))))
                LabeledContent(L10n.t("Subfolders"), value: L10n.f("%@ items", String(describing: (stats.directoryCount))))
            } else {
                HStack {
                    Text(L10n.t("Scan Failed")).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.t("Rescan")) { Task { await scanFolder() } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    /// 执行一次文件夹扫描，代次递增避免面板重建时并发的旧任务回填覆盖新结果。
    @State private var scanGeneration = 0
    private func scanFolder() async {
        scanGeneration += 1
        let generation = scanGeneration
        statsLoading = true
        let result = await model.folderStats(for: file)
        guard generation == scanGeneration else { return }
        folderStats = result
        statsLoading = false
    }

    private var locationSection: some View {
        Section(L10n.t("Location")) {
            Text(file.path)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var kindLabel: String {
        switch FileKind(file: file) {
        case .directory: return L10n.t("Folder")
        case .image: return L10n.t("Image")
        case .text: return L10n.t("Plain Text")
        case .code: return L10n.t("Source Code")
        case .archive: return L10n.t("Archive")
        case .other: return L10n.t("Document")
        }
    }

    private var byteSize: String {
        FileBrowserModel.sizeText(file.size)
    }
}

/// 待分享内容的 Identifiable 包装，供系统分享面板的 .sheet(item:) 使用。
/// 支持单个或多个文件（多选分享时一次分享多份）。
struct ShareItem: Identifiable {
    let urls: [URL]
    var id: String { urls.map(\.absoluteString).joined(separator: "|") }
    init(url: URL) { self.urls = [url] }
    init(urls: [URL]) { self.urls = urls }
}

/// 系统原生分享面板（UIActivityViewController），对齐文件 App 的分享交互。
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
