import SwiftUI

/// 存储卷管理页：展示 Docker 卷列表，支持创建 / 删除。
/// 对标 1Panel 容器-存储卷；所有命令经 DockerService 统一构造与 quote。
struct VolumeListView: View {
    private let service = DockerService.shared

    @State private var volumes: [DockerVolume] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var confirmRemove: DockerVolume?
    @State private var operationError: String?
    @State private var searchText = ""
    @State private var showCreate = false
    @State private var successMessage: String?

    private var filtered: [DockerVolume] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return volumes }
        return volumes.filter {
            $0.name.lowercased().contains(query) || $0.driver.lowercased().contains(query)
        }
    }

    var body: some View {
        ZStack {
            List {
                Section {
                    Button { showCreate = true } label: {
                        Label(L10n.t("Create volume"), systemImage: "plus.circle")
                    }
                } footer: {
                    Text(L10n.t("Volumes persist data independently of containers. Volumes in use by containers cannot be removed."))
                }

                if let error = errorMessage {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }

                Section {
                    ForEach(filtered) { volume in
                        volumeRow(volume)
                    }
                }

                if filtered.isEmpty && !isLoading {
                    VStack(spacing: 10) {
                        Image(systemName: "externaldrive")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        Text(searchText.isEmpty ? L10n.t("No volumes") : L10n.t("No matching volumes"))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
            }
            .listStyle(.insetGrouped)

            if isLoading && volumes.isEmpty {
                ProgressView(L10n.t("Loading volumes…"))
            }
        }
        .searchable(text: $searchText, prompt: Text(L10n.t("Search volumes")))
        .searchToolbarBehavior(.minimize)
        .refreshable { await load() }
        .task { await load() }
        .onReceive(AppEventBus.shared.serverChanges()) { _ in
            Task {
                volumes = []
                await load()
            }
        }
        .onReceive(AppEventBus.shared.containerChanges()) { _ in
            Task { await load() }
        }
        .sheet(isPresented: $showCreate) {
            CreateVolumeView { message in
                successMessage = message
                await load()
            }
        }
        .alert(L10n.t("Remove Volume"), isPresented: Binding(
            get: { confirmRemove != nil },
            set: { if !$0 { confirmRemove = nil } }
        )) {
            Button(L10n.t("Cancel"), role: .cancel) { confirmRemove = nil }
            Button(L10n.t("Delete"), role: .destructive) {
                if let volume = confirmRemove {
                    Task {
                        let result = await service.removeVolume(name: volume.name)
                        if case .failure(let error) = result { operationError = error.localizedDescription }
                        else { successMessage = L10n.f("Volume removed: %@", volume.name) }
                        await load()
                    }
                    confirmRemove = nil
                }
            }
        } message: {
            Text(L10n.f("Remove volume \"%@\"? Data in this volume will be permanently deleted.", String(describing: (confirmRemove?.name ?? ""))))
        }
        .alert(L10n.t("Operation failed"), isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button(L10n.t("OK"), role: .cancel) { operationError = nil }
        } message: {
            Text(operationError ?? "")
        }
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

    private func volumeRow(_ volume: DockerVolume) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(volume.name)
                    .font(.subheadline.weight(.medium).monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 10) {
                    if !volume.driver.isEmpty { Text(volume.driver) }
                    if !volume.size.isEmpty { Text(volume.size) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Menu {
                Button(role: .destructive) { confirmRemove = volume } label: {
                    Label(L10n.t("Remove Volume"), systemImage: "trash")
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

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            volumes = try await service.fetchVolumeList()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 创建存储卷

private struct CreateVolumeView: View {
    let onDone: (String) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var driver = "local"
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.t("Volume name"), text: $name)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker(L10n.t("Driver"), selection: $driver) {
                        ForEach(["local"], id: \.self) { Text($0).tag($0) }
                    }
                } header: {
                    Text(L10n.t("Volume details"))
                } footer: {
                    Text(L10n.t("Leave the name empty to let Docker generate a random name. Name allows letters, digits, dots, underscores and hyphens."))
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.caption) }
                }
            }
            .navigationTitle(L10n.t("Create volume"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("Create")) { Task { await create() } }
                        .fontWeight(.semibold)
                        .disabled(busy || (name.trimmingCharacters(in: .whitespaces).isEmpty ? false : !DockerService.validResourceName(name.trimmingCharacters(in: .whitespaces))))
                }
            }
            .overlay {
                if busy {
                    ProgressView(L10n.t("Creating volume…"))
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func create() async {
        let n = name.trimmingCharacters(in: .whitespaces)
        busy = true
        error = nil
        defer { busy = false }
        let result = await DockerService.shared.createVolume(name: n, driver: driver)
        switch result {
        case .success:
            await onDone(n.isEmpty ? L10n.t("Volume created") : L10n.f("Volume created: %@", n))
            dismiss()
        case .failure(let e):
            error = e.localizedDescription
        }
    }
}
