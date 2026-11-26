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
                                    .font(.subheadline.weight(.medium).monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .minimumScaleFactor(0.8)
                                HStack(spacing: 10) {
                                    Text(image.size)
                                    Text(image.createdSince)
                                    if Int(image.containers) ?? 0 > 0 {
                                        Text(L10n.f("In use by %@", String(describing: (image.containers))))
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
                                    .font(.subheadline)
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
                        Text(searchText.isEmpty ? "No images" : "No matching images")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
            }
            .listStyle(.insetGrouped)

            if isLoading && images.isEmpty {
                ProgressView("Loading images…")
            }
        }
        .searchable(text: $searchText, prompt: "Search images")
        // 与容器页、文件模块统一：未聚焦时收缩为放大镜按钮。
        .searchToolbarBehavior(.minimize)
        .refreshable { await load() }
        .task { await load() }
        .alert(L10n.t("Remove Image"), isPresented: Binding(
            get: { confirmRemove != nil },
            set: { if !$0 { confirmRemove = nil } }
        )) {
            Button(L10n.t("Cancel"), role: .cancel) { confirmRemove = nil }
            Button(L10n.t("Delete"), role: .destructive) {
                if let image = confirmRemove {
                    Task {
                        _ = await service.removeImage(image.id)
                        await load()
                    }
                    confirmRemove = nil
                }
            }
        } message: {
            Text(L10n.f("Remove image \"%@\"? If it is in use by a container, removal will fail.", String(describing: (confirmRemove?.fullName ?? ""))))
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
