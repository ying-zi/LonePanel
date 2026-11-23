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

    var body: some View {
        NavigationStack {
            List {
                headerSection
                attributesSection
                if file.isDirectory { folderStatsSection }
                locationSection
            }
            .navigationTitle("信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                guard file.isDirectory else { return }
                statsLoading = true
                let result = await model.folderStats(for: file)
                folderStats = result
                statsLoading = false
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
        Section("属性") {
            LabeledContent("种类", value: kindLabel)
            // 文件夹的 STAT size 无意义（见 folderStatsSection），只给文件显示大小。
            if !file.isDirectory {
                LabeledContent("大小", value: byteSize)
            }
            if let date = file.modified {
                LabeledContent("修改日期", value: date.formatted(date: .abbreviated, time: .shortened))
            }
            LabeledContent("权限", value: file.permissionText)
            LabeledContent("属主", value: ownerText)
        }
    }

    /// 文件夹真实统计：磁盘占用 / 文件数 / 子目录数。
    /// SFTP STAT 的目录 size 只是一个固定值（通常 4096），不代表实际占用，
    /// 因此这里展示通过 SSH du/find 命令测得的数据；加载中显示转圈，失败显示未知。
    @ViewBuilder
    private var folderStatsSection: some View {
        Section("内容") {
            if statsLoading {
                HStack {
                    Text("正在统计磁盘占用…")
                    Spacer()
                    ProgressView()
                }
            } else if let stats = folderStats {
                LabeledContent("磁盘占用", value: FileBrowserModel.sizeText(stats.sizeBytes))
                LabeledContent("文件", value: "\(stats.fileCount) 个")
                LabeledContent("子目录", value: "\(stats.directoryCount) 个")
            } else {
                LabeledContent("磁盘占用", value: "无法获取")
                LabeledContent("文件", value: "未知")
                LabeledContent("子目录", value: "未知")
            }
        }
    }

    private var locationSection: some View {
        Section("位置") {
            Text(file.path)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var kindLabel: String {
        switch FileKind(file: file) {
        case .directory: return "文件夹"
        case .image: return "图像"
        case .text: return "纯文本文稿"
        case .code: return "源代码"
        case .archive: return "归档文件"
        case .other: return "文稿"
        }
    }

    private var byteSize: String {
        FileBrowserModel.sizeText(file.size)
    }

    private var ownerText: String {
        let uid = file.uid.map(String.init) ?? "未知"
        let gid = file.gid.map(String.init) ?? "未知"
        return "UID \(uid) · GID \(gid)"
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
