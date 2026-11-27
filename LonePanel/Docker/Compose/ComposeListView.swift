import SwiftUI

/// Compose 项目列表页：**只读**展示项目与状态，点卡片进详情页查看组成。
/// 刻意不在编排页提供任何启停/重启操作——`docker compose down` 会连容器一起删除
/// （用户实测「停止」后容器彻底消失），容器的启停统一在「容器」分区的卡片/详情页完成。
/// 列表行遵循统一卡片形态：左侧状态色条 + 状态徽章 + 信息；整行可点进详情。
struct ComposeListView: View {
    private let service = DockerService.shared

    @State private var projects: [DockerComposeProject] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    /// 点卡片进详情。Identifiable + Hashable 满足 navigationDestination(item:)。
    @State private var detailTarget: DockerComposeProject?

    /// 与容器/镜像/网络/卷分区统一：按项目名过滤搜索。
    private var filtered: [DockerComposeProject] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return projects }
        return projects.filter { $0.name.lowercased().contains(query) }
    }

    var body: some View {
        ZStack {
            List {
                if let error = errorMessage {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }

                ForEach(filtered) { project in
                    composeRow(project)
                }

                if filtered.isEmpty && !isLoading && errorMessage == nil {
                    emptyView
                }
            }
            .listStyle(.insetGrouped)

            if isLoading && projects.isEmpty {
                ProgressView(L10n.t("Loading Compose projects…"))
            }
        }
        .searchable(text: $searchText, prompt: Text(L10n.t("Search Compose projects")))
        // 与容器/镜像/网络/卷分区统一：未聚焦时收缩为放大镜按钮，右上角工具栏结构一致。
        .searchToolbarBehavior(.minimize)
        .refreshable { await load() }
        .task { await load() }
        // 切服事件：清空旧服务器 Compose 项目并重载。
        .onReceive(AppEventBus.shared.serverChanges()) { _ in
            Task {
                projects = []
                await load()
            }
        }
        // 编排部署/容器变更事件：重载项目列表（模板部署成功会广播 containersChanged）。
        .onReceive(AppEventBus.shared.containerChanges()) { _ in
            Task { await load() }
        }
        // 点卡片进详情页（只读查看项目组成：概览 + 服务列表 + yml 内容）。
        .navigationDestination(item: $detailTarget) { project in
            ComposeProjectDetailView(project: project)
        }
    }

    // MARK: - 行

    /// 项目卡片：左侧色条 + 名称/状态徽章 + 配置路径 + 可点进详情的箭头。
    /// 刻意不放任何操作按钮：编排页只查看，启停统一在容器分区做。
    private func composeRow(_ project: DockerComposeProject) -> some View {
        ZStack(alignment: .leading) {
            Color(.secondarySystemGroupedBackground)
            HStack(spacing: 0) {
                StatusStripe(state: project.state)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .padding(.vertical, 11)

                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(project.name)
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if !project.configFiles.isEmpty {
                            Text(project.configFiles)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 4)
                    StatusBadge(state: project.state)
                        .fixedSize()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, 12)
                .padding(.trailing, 12)
                .padding(.vertical, 11)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
        .contentShape(Rectangle())
        .onTapGesture { detailTarget = project }
        .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(searchText.isEmpty
                 ? L10n.t("No Compose projects")
                 : L10n.t("No matching Compose projects"))
                .foregroundStyle(.secondary)
            Text(L10n.t("All Compose projects on this server appear here, including running, stopped and created ones."))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - 加载

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            projects = try await service.fetchComposeProjects()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 编排项目详情

/// 编排项目详情页：**只读**查看项目组成——项目概览 + 服务/容器列表（可跳容器详情）+ yml 内容。
/// 刻意不提供启停/重启/删除/编辑：编排的 `down` 会连容器一起删除（用户实测容器消失），
/// 容器的启停统一在「容器」分区做，yml 的编辑/项目删除今后如需再以安全方式单独设计。
struct ComposeProjectDetailView: View {
    let project: DockerComposeProject

    private let service = DockerService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var services: [ComposeService] = []
    @State private var yaml: String = ""
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        List {
            // 项目摘要：状态 + 配置文件路径。
            Section {
                HStack {
                    Text(L10n.t("Status"))
                    Spacer()
                    StatusBadge(state: project.state)
                }
                HStack(alignment: .top) {
                    Text(L10n.t("Config file"))
                    Spacer(minLength: 12)
                    Text(project.primaryConfigFile.isEmpty ? L10n.t("Unknown") : project.primaryConfigFile)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(3)
                }
                if !project.status.isEmpty {
                    InfoRow(title: L10n.t("Compose status"), value: project.status)
                }
            } header: {
                Text(L10n.t("Project overview"))
            }

            // 服务列表：点条目跨模块跳容器详情调用态。
            Section {
                if isLoading {
                    HStack {
                        ProgressView()
                        Text(L10n.t("Loading services…")).foregroundStyle(.secondary)
                    }
                } else if let error = loadError {
                    Text(error).foregroundStyle(.red).font(.footnote)
                } else if services.isEmpty {
                    Text(L10n.t("No services found for this project"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(services) { svc in
                        Button {
                            openContainer(svc)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "cube.fill")
                                    .foregroundStyle(DockerStateStyle.color(svc.state))
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(svc.serviceName.isEmpty ? svc.containerName : svc.serviceName)
                                            .font(.subheadline.weight(.medium))
                                        StatusBadge(state: svc.state)
                                    }
                                    Text(svc.containerName)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                    if !svc.image.isEmpty {
                                        Text(svc.image)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    if !svc.ports.isEmpty {
                                        Text(svc.ports)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text(L10n.t("Services"))
            } footer: {
                Text(L10n.t("Tap a service to open its container details."))
            }

            // Compose 文件内容：只读展示，方便核对端口/环境变量等配置。
            if !yaml.isEmpty {
                Section {
                    Text(yaml)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineSpacing(2)
                } header: {
                    Text(L10n.t("Compose file content"))
                }
            }
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        // 切服 / 容器变更：本页数据属于旧服务器或已过期，pop 回列表让列表自己刷新。
        .onReceive(AppEventBus.shared.serverChanges()) { _ in dismiss() }
        .onReceive(AppEventBus.shared.containerChanges()) { _ in Task { await load() } }
    }

    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        let cfg = project.primaryConfigFile
        guard !cfg.isEmpty else {
            loadError = L10n.t("Compose config file path is unavailable")
            return
        }
        async let servicesTask = service.fetchComposeServices(configFile: cfg, project: project.name)
        async let yamlTask = service.fetchComposeFileContent(path: cfg)
        let servicesResult = await servicesTask
        let yamlResult = await yamlTask
        switch servicesResult {
        case .success(let list): services = list
        case .failure(let e): loadError = e.localizedDescription
        }
        if case .success(let text) = yamlResult { yaml = text }
    }

    private func openContainer(_ svc: ComposeService) {
        guard !svc.id.isEmpty else { return }
        ModuleCoordinator.shared.openContainerDetail(id: svc.id, title: svc.serviceName.isEmpty ? svc.containerName : svc.serviceName)
    }
}
