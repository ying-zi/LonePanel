import SwiftUI
import UIKit
import QuickLook

/// 文件详情页：文本只读预览/搜索/编码切换、图片缩放预览、底部操作条、
/// 编辑态与属性展示。遵循系统原生控件优先：分享走 UIActivityViewController，
/// 大图放大走系统 QuickLook。
struct FileDetailView: View {
    @ObservedObject var model: FileBrowserModel
    let file: RemoteFile
    var onRename: (RemoteFile) -> Void
    var onMove: (RemoteFile) -> Void
    var onDelete: (RemoteFile) -> Void

    @State private var searchText = ""
    @State private var shareItem: ShareItem?
    @State private var quickLookURL: URL?
    @FocusState private var editorFocused: Bool

    private var kind: RemoteFileKind { RemoteFileKind(file: file) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                previewSection
                attributesSection
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(model.isEditing)
        .searchable(text: $searchText, prompt: "在文件中搜索")
        .toolbar {
            if model.isEditing {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { model.closeDetail() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { Task { await model.saveEditing() } }
                        .fontWeight(.semibold)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            if let url = model.exportURL() { shareItem = ShareItem(url: url) }
                        } label: {
                            Label("分享 / 导出", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            quickLookURL = model.exportURL()
                        } label: {
                            Label("全屏查看", systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            actionBar
        }
        .sheet(item: $shareItem) { item in
            ActivityShareSheet(item: item.url)
        }
        .quickLookPreview($quickLookURL)
        .alert("放弃修改？", isPresented: $model.showDiscardConfirm) {
            Button("放弃", role: .destructive) { model.forceCloseDetail() }
            Button("继续编辑", role: .cancel) { model.showDiscardConfirm = false }
        } message: {
            Text("你有未保存的修改，退出后将丢失。")
        }
        .task {
            await model.openDetail(file)
        }
        .onChange(of: model.detailEncoding) { _, _ in
            if model.isEditing { model.editBuffer = model.detailText ?? "" }
        }
    }

    // MARK: - 预览区

    @ViewBuilder
    private var previewSection: some View {
        if model.isEditing {
            TextEditor(text: $model.editBuffer)
                .focused($editorFocused)
                .frame(minHeight: 320)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                }
        } else {
            switch kind {
            case .text:
                textPreview
            case .image:
                imagePreview
            case .directory, .other:
                genericPreview
            }
        }
    }

    private var textPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("编码", selection: $model.detailEncoding) {
                ForEach(FileTextEncoding.allCases) { enc in
                    Text(enc.rawValue).tag(enc)
                }
            }
            .pickerStyle(.menu)

            if model.detailLoadFailed {
                ContentUnavailableView {
                    Label("无法读取文件", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("请检查文件权限或网络连接后重试")
                } actions: {
                    Button("重试") { Task { await model.reloadDetailBytes() } }
                }
                .frame(minHeight: 240)
            } else if let text = model.detailText {
                Text(highlighted(text))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ProgressView("加载中…")
                    .frame(maxWidth: .infinity, minHeight: 240)
            }
        }
    }

    private var imagePreview: some View {
        Group {
            if let image = model.detailImage {
                ZoomableImageView(image: image)
                    .frame(maxWidth: .infinity, minHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if model.detailLoadFailed {
                ContentUnavailableView("无法读取图片", systemImage: "photo")
                    .frame(minHeight: 240)
            } else {
                ProgressView("加载中…")
                    .frame(maxWidth: .infinity, minHeight: 240)
            }
        }
    }

    private var genericPreview: some View {
        VStack(spacing: 12) {
            Image(systemName: kind == .directory ? "folder.fill" : "doc")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text(kind == .directory ? "文件夹" : "此类型暂不支持预览")
                .foregroundStyle(.secondary)
            Button("用系统查看器打开") { quickLookURL = model.exportURL() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    /// 关键字搜索：按行过滤包含关键字的内容，避免自定义富文本高亮带来的脆弱性。
    private func highlighted(_ text: String) -> AttributedString {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return AttributedString(text) }
        let matched = text.components(separatedBy: .newlines)
            .filter { $0.localizedCaseInsensitiveContains(keyword) }
        let joined = matched.isEmpty ? "无匹配内容" : matched.joined(separator: "\n")
        return AttributedString(joined)
    }

    // MARK: - 属性

    private var attributesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("属性")
                .font(.headline)
            attrRow("大小", byteSize)
            attrRow("修改时间", file.modified?.formatted(date: .abbreviated, time: .shortened) ?? "未知")
            attrRow("权限", file.permissionText)
            attrRow("属主", ownerText)
        }
        .padding(.bottom, 8)
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

    private func attrRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }

    // MARK: - 底部操作条

    private var actionBar: some View {
        HStack(spacing: 4) {
            if model.isEditing {
                actionButton("完成", systemImage: "checkmark") {
                    Task { await model.saveEditing() }
                }
            } else {
                actionButton("编辑", systemImage: "pencil") {
                    model.beginEditing()
                }
                .disabled(kind != .text)
                actionButton("下载", systemImage: "square.and.arrow.down") {
                    if let url = model.exportURL() { shareItem = ShareItem(url: url) }
                }
                actionButton("重命名", systemImage: "pencil") { onRename(file) }
                actionButton("移动", systemImage: "arrow.right") { onMove(file) }
                actionButton("删除", systemImage: "trash", role: .destructive) { onDelete(file) }
            }
        }
        .padding(8)
        .background(.ultraThinMaterial)
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.body)
                Text(title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Color.red : Color.accentColor)
    }
}

/// 可捏合缩放的图片视图：SwiftUI 无原生缩放图片控件，此处组合手势自实现。
private struct ZoomableImageView: View {
    let image: UIImage
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = min(max(lastScale * value, 1), 6)
                        }
                        .onEnded { _ in
                            lastScale = scale
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation { scale = 1; lastScale = 1 }
                }
        }
    }
}

/// URL 的 Identifiable 包装，供 .sheet(item:) 使用。
private struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// 系统分享面板封装。
private struct ActivityShareSheet: UIViewControllerRepresentable {
    let item: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [item], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
