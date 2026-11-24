import SwiftUI

/// 缓存管理：顶部显示总占用并可一键清空；下方按类别列出各项占用、条目数与清理按钮。
/// 只依赖根 Core 的 FileCache，不引用任何功能模块。
struct CacheSettingsView: View {
    @State private var total: Int64 = 0
    @State private var categories: [CacheCategoryUsage] = []
    @State private var confirmAll = false
    @State private var pendingCategory: CacheCategoryUsage?

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 34))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("已占用缓存")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(formatBytes(total))
                            .font(.title2.weight(.semibold))
                            .monospacedDigit()
                    }
                    Spacer(minLength: 8)
                    // 纯图标胶囊按钮：宽度大于高度，系统的 .borderedProminent 自然呈胶囊造型。
                    // 固定字号 + 固定尺寸，系统字号放大时不会变形。
                    // .destructive 呈系统红色实心，垃圾桶居中。
                    Button(role: .destructive) {
                        confirmAll = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 24, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(width: 88, height: 48)
                    .accessibilityLabel("全部清理")
                    .disabled(total == 0)
                }
                .padding(.vertical, 6)
            } footer: {
                Text("缓存用于加快文件预览与分享，可随时清理，不影响服务器上的数据。超出 1 GB 时 App 会自动清理最久未使用的部分。")
            }

            if !categories.isEmpty {
                Section("按类别") {
                    ForEach(categories) { item in
                        HStack(spacing: 12) {
                            Image(systemName: categoryIcon(item.category))
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(categoryTitle(item.category))
                                    .font(.body)
                                Text("\(formatBytes(item.size)) · \(item.count) 项 · \(categoryDetail(item.category))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            // 灰色胶囊垃圾桶：同样的宽胶囊，.bordered 配 .tint(.gray) 与顶部红色区分层级。
                            Button {
                                pendingCategory = item
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 22, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                            .tint(.gray)
                            .frame(width: 80, height: 46)
                            .accessibilityLabel("清理")
                        }
                    }
                }
            }
        }
        .navigationTitle("缓存管理")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
        .alert("清理全部缓存", isPresented: $confirmAll) {
            Button("取消", role: .cancel) {}
            Button("清理", role: .destructive) {
                Task { await FileCache.shared.clearAll(); await reload() }
            }
        } message: {
            Text("将删除所有已缓存的文件副本，下次预览需重新下载。")
        }
        .alert(item: $pendingCategory) { item in
            Alert(
                title: Text("清理「\(categoryTitle(item.category))」"),
                message: Text("将删除该类缓存约 \(formatBytes(item.size))，不影响其他类别。"),
                primaryButton: .destructive(Text("清理")) {
                    Task { await FileCache.shared.clear(category: item.category); await reload() }
                },
                // 显式给文案，走本地化；否则 .cancel() 用系统默认英文 "Cancel"。
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }

    private func reload() async {
        async let t = FileCache.shared.totalSize()
        async let c = FileCache.shared.categoryUsage()
        total = await t
        categories = await c
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / 1024 / 1024) }
        return String(format: "%.2f GB", Double(bytes) / 1024 / 1024 / 1024)
    }

    // 类别展示元数据：新增缓存类别时在这里补一行即可。
    private func categoryTitle(_ category: String) -> String {
        switch category {
        case "files": return "文件预览"
        default: return category
        }
    }

    private func categoryIcon(_ category: String) -> String {
        switch category {
        case "files": return "doc.viewfinder"
        default: return "folder"
        }
    }

    private func categoryDetail(_ category: String) -> String {
        switch category {
        case "files": return "预览与分享时下载的文件副本"
        default: return "本地缓存副本"
        }
    }
}
