import SwiftUI

/// 镜像列表页：展示本地镜像、占用空间，支持删除（含被引用的二次确认提示）。
struct ImageView: View {
    private let service = DockerService.shared

    @State private var images: [DockerImage] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var confirmRemove: DockerImage?
    @State private var searchText = ""

    private var filtered: [DockerImage] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return images }
        return images.filter { $0.fullName.lowercased().contains(query) }
    }

    var body: some View {
        ZStack {
            List {
                if let error = errorMessage {
                    Section {
                        Text(error).foregroundStyle(.red).font(.footnote)
                    }
                }

                Section {
                    ForEach(filtered) { image in
                        HStack(spacing: 12) {
                            Image(systemName: "shippingbox")
                                .font(.title3)
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(image.fullName)
                                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                HStack(spacing: 10) {
                                    Text(image.size)
                                    Text(image.createdSince)
                                    if Int(image.containers) ?? 0 > 0 {
                                        Text("使用中 \(image.containers)")
                                            .foregroundStyle(.orange)
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Button {
                                confirmRemove = image
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                    }
                }

                if filtered.isEmpty && !isLoading {
                    VStack(spacing: 10) {
                        Image(systemName: "shippingbox")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        Text(searchText.isEmpty ? "没有镜像" : "没有匹配的镜像")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
            }
            .listStyle(.insetGrouped)

            if isLoading && images.isEmpty {
                ProgressView("正在读取镜像…")
            }
        }
        .searchable(text: $searchText, prompt: "搜索镜像")
        .refreshable { await load() }
        .task { await load() }
        .alert("删除镜像", isPresented: Binding(
            get: { confirmRemove != nil },
            set: { if !$0 { confirmRemove = nil } }
        )) {
            Button("取消", role: .cancel) { confirmRemove = nil }
            Button("删除", role: .destructive) {
                if let image = confirmRemove {
                    Task {
                        _ = await service.removeImage(image.id)
                        await load()
                    }
                    confirmRemove = nil
                }
            }
        } message: {
            Text("确定删除镜像「\(confirmRemove?.fullName ?? "")」吗？若镜像正被容器使用，删除会失败。")
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            images = try await service.fetchImages()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
