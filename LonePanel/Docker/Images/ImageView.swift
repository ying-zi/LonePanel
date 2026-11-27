import SwiftUI

/// 镜像列表页：展示本地镜像、占用空间，支持拉取 / 打标签 / 导出 / 导入 / 删除。
/// 对标 1Panel 镜像管理；所有命令经 DockerService 统一构造与 quote。
struct ImageView: View {
    private let service = DockerService.shared

    @State private var images: [DockerImage] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var confirmRemove: DockerImage?
    @State private var operationError: String?
    @State private var searchText = ""
    /// 当前镜像操作（拉取/打标签/导出/导入）。统一用一个 sheet 出口，避免多个 sheet 打架。
    @State private var action: ImageAction?
    /// 操作成功的短提示（如"已拉取""已导出到…"）。
    @State private var successMessage: String?

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
                        imageRow(image)
                    }
                }

                if filtered.isEmpty && !isLoading {
                    VStack(spacing: 10) {
                        Image(systemName: "shippingbox")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        Text(searchText.isEmpty ? L10n.t("No images") : L10n.t("No matching images"))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
            }
            .listStyle(.insetGrouped)

            if isLoading && images.isEmpty {
                ProgressView(L10n.t("Loading images…"))
            }
        }
        .searchable(text: $searchText, prompt: Text(L10n.t("Search images")))
        // 与容器页、文件模块统一：未聚焦时收缩为放大镜按钮。
        .searchToolbarBehavior(.minimize)
        .refreshable { await load() }
        .task { await load() }
        // 切服事件：清空旧服务器镜像并重载。
        .onReceive(AppEventBus.shared.serverChanges()) { _ in
            Task {
                images = []
                await load()
            }
        }
        // 容器/镜像变更事件：别处拉取或删除镜像后，本页同步刷新。
        .onReceive(AppEventBus.shared.containerChanges()) { _ in
            Task { await load() }
        }
        // 右上 ⋯ 的新建入口：镜像分区当前在树里，收到请求后弹出对应表单。
        .onReceive(AppEventBus.shared.dockerCreateRequests()) { request in
            switch request {
            case .pullImage: action = .pull
            case .importImage: action = .importFile
            default: break
            }
        }
        .sheet(item: $action) { act in
            actionView(act)
        }
        .alert(L10n.t("Remove Image"), isPresented: Binding(
            get: { confirmRemove != nil },
            set: { if !$0 { confirmRemove = nil } }
        )) {
            Button(L10n.t("Cancel"), role: .cancel) { confirmRemove = nil }
            Button(L10n.t("Delete"), role: .destructive) {
                if let image = confirmRemove {
                    Task {
                        let result = await service.removeImage(image.id)
                        if case .failure(let error) = result { operationError = error.localizedDescription }
                        await load()
                    }
                    confirmRemove = nil
                }
            }
        } message: {
            Text(L10n.f("Remove image \"%@\"? If it is in use by a container, removal will fail.", String(describing: (confirmRemove?.fullName ?? ""))))
        }
        .alert(L10n.t("Operation failed"), isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button(L10n.t("OK"), role: .cancel) { operationError = nil }
        } message: {
            Text(operationError ?? "")
        }
        // 成功提示：2.8 秒后自动消失。
        .overlay(alignment: .top) {
            if let message = successMessage {
                Text(message)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(nanoseconds: 2_800_000_000)
                        successMessage = nil
                    }
            }
        }
        .animation(.easeInOut, value: successMessage)
    }

    // MARK: - 行

    private func imageRow(_ image: DockerImage) -> some View {
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
            // 单镜像操作统一收进一个更多菜单，避免行尾堆多个按钮挤占宽度。
            Menu {
                Button { action = .tag(image) } label: {
                    Label(L10n.t("Add tag"), systemImage: "tag")
                }
                Button { action = .export(image) } label: {
                    Label(L10n.t("Export image"), systemImage: "square.and.arrow.up")
                }
                Divider()
                Button(role: .destructive) { confirmRemove = image } label: {
                    Label(L10n.t("Remove Image"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    // MARK: - 操作表单分派

    @ViewBuilder
    private func actionView(_ act: ImageAction) -> some View {
        switch act {
        case .pull:
            PullImageView { message in
                successMessage = message
                await load()
            }
        case .tag(let image):
            TagImageView(image: image) { message in
                successMessage = message
                await load()
            }
        case .export(let image):
            ExportImageView(image: image) { message in
                successMessage = message
            }
        case .importFile:
            ImportImageView { message in
                successMessage = message
                await load()
            }
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

// MARK: - 镜像操作枚举

/// 镜像页的四种操作。Identifiable 供 .sheet(item:) 使用。
private enum ImageAction: Identifiable {
    case pull
    case tag(DockerImage)
    case export(DockerImage)
    case importFile

    var id: String {
        switch self {
        case .pull: return "pull"
        case .tag(let image): return "tag-\(image.id)"
        case .export(let image): return "export-\(image.id)"
        case .importFile: return "import"
        }
    }
}

// MARK: - 拉取镜像

private struct PullImageView: View {
    let onDone: (String) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reference = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("nginx:latest", text: $reference)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text(L10n.t("Image reference"))
                } footer: {
                    Text(L10n.t("Enter a full reference such as nginx:latest or registry.example.com/app:v1."))
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red).font(.caption)
                    }
                }
            }
            .navigationTitle(L10n.t("Pull image"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("Pull")) { Task { await pull() } }
                        .fontWeight(.semibold)
                        .disabled(busy || reference.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .overlay {
                if busy {
                    ProgressView(L10n.t("Pulling image…"))
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func pull() async {
        let ref = reference.trimmingCharacters(in: .whitespaces)
        busy = true
        error = nil
        defer { busy = false }
        let result = await DockerService.shared.pullImage(ref)
        switch result {
        case .success:
            await onDone(L10n.f("Pulled %@", ref))
            dismiss()
        case .failure(let e):
            error = e.localizedDescription
        }
    }
}

// MARK: - 打标签

private struct TagImageView: View {
    let image: DockerImage
    let onDone: (String) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var repository: String
    @State private var tag: String
    @State private var busy = false
    @State private var error: String?

    init(image: DockerImage, onDone: @escaping (String) async -> Void) {
        self.image = image
        self.onDone = onDone
        _repository = State(initialValue: image.repository)
        _tag = State(initialValue: image.tag)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.t("Repository"), text: $repository)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField(L10n.t("Tag"), text: $tag)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text(L10n.t("New tag for this image"))
                } footer: {
                    Text(L10n.f("Runs docker tag on image %@. Leave tag empty to use the repository name only.", String(describing: (image.id.prefix(12)))))
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red).font(.caption)
                    }
                }
            }
            .navigationTitle(L10n.t("Add tag"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("Save")) { Task { await tag() } }
                        .fontWeight(.semibold)
                        .disabled(busy || repository.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .overlay {
                if busy {
                    ProgressView().padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func tag() async {
        busy = true
        error = nil
        defer { busy = false }
        let result = await DockerService.shared.tagImage(
            sourceID: image.id,
            repository: repository,
            tag: tag
        )
        switch result {
        case .success:
            let ref = tag.isEmpty ? repository : "\(repository):\(tag)"
            await onDone(L10n.f("Tagged as %@", ref))
            dismiss()
        case .failure(let e):
            error = e.localizedDescription
        }
    }
}

// MARK: - 导出镜像

private struct ExportImageView: View {
    let image: DockerImage
    let onDone: (String) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var directory = "/tmp"
    @State private var filename: String
    /// 本地目录选择目标：本表单是 sheet，必须用本地 .folderPicker 承载，
    /// 才能做到「选完目录只关选择器、本表单不收起」。
    @State private var pickTarget: ModuleCoordinator.FileOpenTarget?
    @State private var busy = false
    @State private var error: String?

    init(image: DockerImage, onDone: @escaping (String) async -> Void) {
        self.image = image
        self.onDone = onDone
        let base = image.repository.replacingOccurrences(of: "/", with: "_")
        let version = image.tag.isEmpty ? "latest" : image.tag
        _filename = State(initialValue: "\(base)_\(version).tar")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        pickTarget = ModuleCoordinator.shared.directoryPickTarget(
                            at: directory,
                            title: L10n.t("Choose export directory")
                        ) { picked in
                            directory = picked
                        }
                    } label: {
                        HStack {
                            Image(systemName: "folder").foregroundStyle(.tint)
                            Text(directory).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    TextField(L10n.t("File name"), text: $filename)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text(L10n.t("Export destination"))
                } footer: {
                    Text(L10n.t("Saves the image as a tar archive in a directory on the server. Add .tar.gz as the suffix to compress."))
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red).font(.caption)
                    }
                }
            }
            .navigationTitle(L10n.t("Export image"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("Export")) { Task { await export() } }
                        .fontWeight(.semibold)
                        .disabled(busy)
                }
            }
            // 目录选择器挂在本表单层级：选完只关选择器，表单不收起。
            .folderPicker(item: $pickTarget)
            .overlay {
                if busy {
                    ProgressView(L10n.t("Exporting image…"))
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func export() async {
        busy = true
        error = nil
        defer { busy = false }
        let result = await DockerService.shared.exportImage(
            imageID: image.id,
            directory: directory,
            filename: filename
        )
        switch result {
        case .success(let path):
            await onDone(L10n.f("Exported to %@", path))
            dismiss()
        case .failure(let e):
            error = e.localizedDescription
        }
    }
}

// MARK: - 导入镜像

private struct ImportImageView: View {
    let onDone: (String) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var directory = "/tmp"
    @State private var filename = ""
    @State private var pickTarget: ModuleCoordinator.FileOpenTarget?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        pickTarget = ModuleCoordinator.shared.directoryPickTarget(
                            at: directory,
                            title: L10n.t("Choose archive directory")
                        ) { picked in
                            directory = picked
                        }
                    } label: {
                        HStack {
                            Image(systemName: "folder").foregroundStyle(.tint)
                            Text(directory).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    TextField(L10n.t("Archive file name (e.g. backup.tar)"), text: $filename)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text(L10n.t("Tar archive on server"))
                } footer: {
                    Text(L10n.t("Select the directory on the server that holds the archive, then enter its file name. Runs docker load -i."))
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red).font(.caption)
                    }
                }
            }
            .navigationTitle(L10n.t("Import image"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("Import")) { Task { await importImage() } }
                        .fontWeight(.semibold)
                        .disabled(busy || filename.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .folderPicker(item: $pickTarget)
            .overlay {
                if busy {
                    ProgressView(L10n.t("Importing image…"))
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func importImage() async {
        let name = filename.trimmingCharacters(in: .whitespaces)
        let path = directory.hasSuffix("/") ? directory + name : directory + "/" + name
        busy = true
        error = nil
        defer { busy = false }
        let result = await DockerService.shared.importImage(tarPath: path)
        switch result {
        case .success:
            await onDone(L10n.t("Image imported"))
            dismiss()
        case .failure(let e):
            error = e.localizedDescription
        }
    }
}
