import SwiftUI
import UIKit

/// 系统风格的「获取信息」面板：对齐 iOS 26 文件 App 的 Info 页面，
/// 顶部大图标 + 文件名，下面用原生 List/LabeledContent 列出属性。
/// 单击文件本身改为系统 QuickLook 预览，不在这里做自定义文本编辑/编码切换。
struct FileInfoSheet: View {
    let file: RemoteFile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                headerSection
                attributesSection
                locationSection
            }
            .navigationTitle("信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
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
            LabeledContent("大小", value: byteSize)
            if let date = file.modified {
                LabeledContent("修改日期", value: date.formatted(date: .abbreviated, time: .shortened))
            }
            LabeledContent("权限", value: file.permissionText)
            LabeledContent("属主", value: ownerText)
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
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: file.size)
    }

    private var ownerText: String {
        let uid = file.uid.map(String.init) ?? "未知"
        let gid = file.gid.map(String.init) ?? "未知"
        return "UID \(uid) · GID \(gid)"
    }
}

/// URL 的 Identifiable 包装，供系统分享面板的 .sheet(item:) 使用。
struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// 系统原生分享面板（UIActivityViewController），对齐文件 App 的分享交互。
struct ActivityShareSheet: UIViewControllerRepresentable {
    let item: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [item], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
