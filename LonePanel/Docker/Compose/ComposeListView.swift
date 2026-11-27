import SwiftUI

/// Compose 项目列表页：展示项目与状态，点卡片进详情页做完整运维。
/// 列表行遵循统一卡片形态：左侧状态色条 + 状态徽章 + 单一主操作 + ⋯（其余操作收进来）。
struct ComposeListView: View {
    private let service = DockerService.shared

    @State private var projects: [DockerComposeProject] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var actionTarget: DockerComposeProject?
    @State private var pendingAction: DockerService.ComposeAction?
    @State private var operationError: String?
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
        // 点卡片进详情页（独立任务范式：push，完成后不必返回列表）。
        .navigationDestination(item: $detailTarget) { project in
            ComposeProjectDetailView(project: project)
        }
        .alert(alertTitle, isPresented: Binding(
            get: { pendingAction != nil },
            set: { if !$0 { pendingAction = nil } }
        )) {
            Button(L10n.t("Cancel"), role: .cancel) { pendingAction = nil }
            Button(L10n.t("OK")) {
                if let project = actionTarget, let action = pendingAction {
                    Task {
                        let result = await service.composeAction(
                            project.name,
                            configFile: project.configFiles,
                            action: action
                        )
                        if case .failure(let error) = result { operationError = error.localizedDescription }
                        await load()
                    }
                }
                pendingAction = nil
            }
        } message: {
            Text(L10n.f("Perform %@ on \"%@\"? Compose actions affect all containers in this project.", String(describing: (actionLabel)), String(describing: (actionTarget?.name ?? ""))))
        }
        .alert(L10n.t("Operation failed"), isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button(L10n.t("OK"), role: .cancel) { operationError = nil }
        } message: {
            Text(operationError ?? "")
        }
    }

    // MARK: - 行

    /// 项目卡片：左侧色条 + 名称/状态徽章 + 配置路径 + 主操作 + ⋯；整行可点进详情。
    private func composeRow(_ project: DockerComposeProject) -> some View {
        ZStack(alignment: .leading) {
            Color(.secondarySystemGroupedBackground)
            HStack(spacing: 0) {
                StatusStripe(state: project.state)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .padding(.vertical, 11)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.stack.3d.up")
                            .foregroundStyle(.tint)
                        Text(project.name)
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 4)
                        StatusBadge(state: project.state)
                            .fixedSize()
                    }
                    if !project.configFiles.isEmpty {
                        Text(project.configFiles)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    HStack(spacing: 8) {
                        // 单一主操作：运行/暂停→停止（down），已停止→启动（up）。
                        Button {
                            confirm(project, project.state == .stopped ? .up : .down)
                        } label: {
                            Label(project.state == .stopped ? L10n.t("Start") : L10n.t("Stop"),
                                  systemImage: project.state == .stopped ? "play.fill" : "stop.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        // 其余操作收进 ⋯，与容器列表行一致，不在行内平铺。
                        Menu {
                            Button {
                                confirm(project, .restart)
                            } label: {
                                Label(L10n.t("Restart"), systemImage: "arrow.clockwise")
                            }
                            Button {
                                detailTarget = project
                            } label: {
                                Label(L10n.t("Project details"), systemImage: "doc.text.magnifyingglass")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(width: 32, height: 28)
                                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
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

    // MARK: - 动作

    private func confirm(_ project: DockerComposeProject, _ action: DockerService.ComposeAction) {
        actionTarget = project
        pendingAction = action
    }

    private var alertTitle: String {
        guard let action = pendingAction else { return L10n.t("Confirm Action") }
        switch action {
        case .up: return L10n.t("Start Compose Project")
        case .down: return L10n.t("Stop Compose Project")
        case .restart: return L10n.t("Restart Compose Project")
        }
    }

    private var actionLabel: String {
        guard let action = pendingAction else { return "" }
        switch action {
        case .up: return L10n.t("Start")
        case .down: return L10n.t("Stop")
        case .restart: return L10n.t("Restart")
        }
    }

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

/// 编辑编排载荷：携带覆盖原文件所需的路径 + 项目名 + 当前 yml，Identifiable 供 push。
private struct ComposeEditPayload: Identifiable, Hashable {
    let id = UUID()
    let projectName: String
    let configPath: String
    let yaml: String
}

/// 编排项目详情页：项目摘要 + 服务/容器列表（可跳容器详情）+ 编辑 yml + 启停 + 删除项目。
/// 作为列表页 navigationDestination(item:) 的 push 目标，是「查看+运维某项目」的独立任务页。
struct ComposeProjectDetailView: View {
    let project: DockerComposeProject

    private let service = DockerService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var services: [ComposeService] = []
    @State private var yaml: String = ""
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var operationError: String?
    @State private var pendingAction: DockerService.ComposeAction?
    @State private var confirmRemove = false
    @State private var isWorking = false
    @State private var editPayload: ComposeEditPayload?

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

            // 运维操作：按项目状态收敛 + 编辑编排。
            Section(L10n.t("Project actions")) {
                Button {
                    pendingAction = project.state == .stopped ? .up : .down
                } label: {
                    Label(project.state == .stopped ? L10n.t("Start project") : L10n.t("Stop project"),
                          systemImage: project.state == .stopped ? "play.fill" : "stop.fill")
                }
                Button {
                    pendingAction = .restart
                } label: {
                    Label(L10n.t("Restart project"), systemImage: "arrow.clockwise")
                }
                Button {
                    openEditor()
                } label: {
                    Label(L10n.t("Edit compose file"), systemImage: "square.and.pencil")
                }
                .disabled(project.primaryConfigFile.isEmpty)
            }

            // 危险操作：删除项目（down + 删 yml，不可恢复）。
            Section {
                Button(role: .destructive) {
                    confirmRemove = true
                } label: {
                    Label(L10n.t("Delete compose project"), systemImage: "trash")
                }
            } footer: {
                Text(L10n.t("Stops all containers in the project and deletes its compose file. This cannot be undone."))
            }
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        // 切服 / 容器变更：本页数据属于旧服务器或已过期，pop 回列表让列表自己刷新。
        .onReceive(AppEventBus.shared.serverChanges()) { _ in dismiss() }
        .onReceive(AppEventBus.shared.containerChanges()) { _ in Task { await load() } }
        // 编辑：push 通用编辑器（编辑模式，覆盖原文件 + 重新部署）。
        .navigationDestination(item: $editPayload) { payload in
            ComposeEditorView(
                title: L10n.t("Edit compose file"),
                projectName: payload.projectName,
                yaml: payload.yaml,
                existingConfigPath: payload.configPath,
                onDeployed: { await load() }
            )
        }
        .alert(actionAlertTitle, isPresented: Binding(
            get: { pendingAction != nil },
            set: { if !$0 { pendingAction = nil } }
        )) {
            Button(L10n.t("Cancel"), role: .cancel) { pendingAction = nil }
            Button(L10n.t("OK")) {
                if let action = pendingAction {
                    Task { await runAction(action) }
                }
                pendingAction = nil
            }
        } message: {
            Text(L10n.f("Perform %@ on \"%@\"? This affects all containers in the project.", String(describing: (actionLabel)), String(describing: project.name)))
        }
        .alert(L10n.t("Delete compose project"), isPresented: $confirmRemove) {
            Button(L10n.t("Cancel"), role: .cancel) {}
            Button(L10n.t("Delete"), role: .destructive) {
                Task { await removeProject() }
            }
        } message: {
            Text(L10n.f("Delete \"%@\"? All containers in it will be stopped and its compose file removed.", String(describing: project.name)))
        }
        .alert(L10n.t("Operation failed"), isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button(L10n.t("OK"), role: .cancel) { operationError = nil }
        } message: {
            Text(operationError ?? "")
        }
        .overlay {
            if isWorking {
                ProgressView()
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var actionAlertTitle: String {
        guard let action = pendingAction else { return L10n.t("Confirm Action") }
        switch action {
        case .up: return L10n.t("Start Compose Project")
        case .down: return L10n.t("Stop Compose Project")
        case .restart: return L10n.t("Restart Compose Project")
        }
    }

    private var actionLabel: String {
        guard let action = pendingAction else { return "" }
        switch action {
        case .up: return L10n.t("Start")
        case .down: return L10n.t("Stop")
        case .restart: return L10n.t("Restart")
        }
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

    private func openEditor() {
        let cfg = project.primaryConfigFile
        guard !cfg.isEmpty else { return }
        editPayload = ComposeEditPayload(projectName: project.name, configPath: cfg, yaml: yaml)
    }

    private func runAction(_ action: DockerService.ComposeAction) async {
        isWorking = true
        defer { isWorking = false }
        let result = await service.composeAction(
            project.name,
            configFile: project.configFiles,
            action: action
        )
        if case .failure(let e) = result {
            operationError = e.localizedDescription
            return
        }
        await load()
    }

    private func removeProject() async {
        isWorking = true
        defer { isWorking = false }
        let result = await service.removeComposeProject(
            configFile: project.primaryConfigFile,
            project: project.name
        )
        switch result {
        case .failure(let e):
            operationError = e.localizedDescription
        case .success:
            dismiss()
        }
    }
}
