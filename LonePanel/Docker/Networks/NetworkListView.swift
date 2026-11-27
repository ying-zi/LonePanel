import SwiftUI

/// 网络管理页：展示 Docker 网络列表，支持创建 / 删除。
/// 对标 1Panel 容器-网络；所有命令经 DockerService 统一构造与 quote。
/// 遵循统一规范：搜索走 .searchable、错误 alert、切服事件清空重载、变更不 dismiss 失败现场。
struct NetworkListView: View {
    private let service = DockerService.shared

    @State private var networks: [DockerNetwork] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var confirmRemove: DockerNetwork?
    @State private var operationError: String?
    @State private var searchText = ""
    /// 创建表单出口（sheet(item:)）。
    @State private var showCreate = false
    @State private var successMessage: String?

    private var filtered: [DockerNetwork] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return networks }
        return networks.filter {
            $0.name.lowercased().contains(query) || $0.driver.lowercased().contains(query)
        }
    }

    var body: some View {
        ZStack {
            List {
                Section {
                    Button { showCreate = true } label: {
                        Label(L10n.t("Create network"), systemImage: "plus.circle")
                    }
                } footer: {
                    Text(L10n.t("Custom networks isolate containers. Built-in bridge, host and none networks cannot be removed."))
                }

                if let error = errorMessage {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }

                Section {
                    ForEach(filtered) { network in
                        networkRow(network)
                    }
                }

                if filtered.isEmpty && !isLoading {
                    VStack(spacing: 10) {
                        Image(systemName: "network")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        Text(searchText.isEmpty ? L10n.t("No networks") : L10n.t("No matching networks"))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
            }
            .listStyle(.insetGrouped)

            if isLoading && networks.isEmpty {
                ProgressView(L10n.t("Loading networks…"))
            }
        }
        .searchable(text: $searchText, prompt: Text(L10n.t("Search networks")))
        .searchToolbarBehavior(.minimize)
        .refreshable { await load() }
        .task { await load() }
        .onReceive(AppEventBus.shared.serverChanges()) { _ in
            Task {
                networks = []
                await load()
            }
        }
        .onReceive(AppEventBus.shared.containerChanges()) { _ in
            Task { await load() }
        }
        .sheet(isPresented: $showCreate) {
            CreateNetworkView { message in
                successMessage = message
                await load()
            }
        }
        .alert(L10n.t("Remove Network"), isPresented: Binding(
            get: { confirmRemove != nil },
            set: { if !$0 { confirmRemove = nil } }
        )) {
            Button(L10n.t("Cancel"), role: .cancel) { confirmRemove = nil }
            Button(L10n.t("Delete"), role: .destructive) {
                if let network = confirmRemove {
                    Task {
                        let result = await service.removeNetwork(name: network.name)
                        if case .failure(let error) = result { operationError = error.localizedDescription }
                        else { successMessage = L10n.f("Network removed: %@", network.name) }
                        await load()
                    }
                    confirmRemove = nil
                }
            }
        } message: {
            Text(L10n.f("Remove network \"%@\"? Containers attached to it must be disconnected first.", String(describing: (confirmRemove?.name ?? ""))))
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

    private func networkRow(_ network: DockerNetwork) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "network")
                .font(.title3)
                .foregroundStyle(network.isSystem ? .secondary : .tint)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(network.name)
                        .font(.subheadline.weight(.medium).monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if network.isSystem {
                        Text(L10n.t("System"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(.systemGray5), in: Capsule())
                    }
                }
                HStack(spacing: 10) {
                    if !network.driver.isEmpty { Text(network.driver) }
                    if !network.scope.isEmpty { Text(network.scope) }
                    if network.isInternal { Text(L10n.t("Internal")) }
                    if network.ipv6 { Text("IPv6") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !network.isSystem {
                Menu {
                    Button(role: .destructive) { confirmRemove = network } label: {
                        Label(L10n.t("Remove Network"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            networks = try await service.fetchNetworkList()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 创建网络

private struct CreateNetworkView: View {
    let onDone: (String) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var driver = "bridge"
    @State private var subnet = ""
    @State private var gateway = ""
    @State private var isInternal = false
    @State private var ipv6 = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.t("Network name"), text: $name)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker(L10n.t("Driver"), selection: $driver) {
                        ForEach(["bridge", "overlay", "macvlan", "ipvlan", "host", "none"], id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                } header: {
                    Text(L10n.t("Network details"))
                } footer: {
                    Text(L10n.t("Name allows letters, digits, dots, underscores and hyphens."))
                }

                Section {
                    TextField(L10n.t("Subnet (e.g. 172.20.0.0/16)"), text: $subnet)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField(L10n.t("Gateway (e.g. 172.20.0.1)"), text: $gateway)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle(L10n.t("Internal network"), isOn: $isInternal)
                    Toggle(L10n.t("Enable IPv6"), isOn: $ipv6)
                } header: {
                    Text(L10n.t("Advanced options"))
                } footer: {
                    Text(L10n.t("Leave subnet and gateway empty to let Docker assign them automatically."))
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.caption) }
                }
            }
            .navigationTitle(L10n.t("Create network"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("Create")) { Task { await create() } }
                        .fontWeight(.semibold)
                        .disabled(busy || !DockerService.validResourceName(name.trimmingCharacters(in: .whitespaces)))
                }
            }
            .overlay {
                if busy {
                    ProgressView(L10n.t("Creating network…"))
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .presentationDetents([.large])
    }

    private func create() async {
        let n = name.trimmingCharacters(in: .whitespaces)
        busy = true
        error = nil
        defer { busy = false }
        let result = await DockerService.shared.createNetwork(
            name: n,
            driver: driver,
            subnet: subnet,
            gateway: gateway,
            isInternal: isInternal,
            ipv6: ipv6
        )
        switch result {
        case .success:
            await onDone(L10n.f("Network created: %@", n))
            dismiss()
        case .failure(let e):
            error = e.localizedDescription
        }
    }
}
