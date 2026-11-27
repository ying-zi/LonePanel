import SwiftUI

/// Compose 项目列表页：展示项目与状态，支持 up / down / restart。
struct ComposeListView: View {
    private let service = DockerService.shared

    @State private var projects: [DockerComposeProject] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var actionTarget: DockerComposeProject?
    @State private var pendingAction: DockerService.ComposeAction?
    @State private var operationError: String?
    @State private var searchText = ""

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
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "square.stack.3d.up")
                                .foregroundStyle(.tint)
                            Text(project.name)
                                .font(.headline)
                            Spacer()
                            Text(project.status)
                                .font(.caption)
                                .foregroundStyle(project.status.lowercased().contains("running") ? .green : .secondary)
                        }
                        if !project.configFiles.isEmpty {
                            Text(project.configFiles)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        HStack(spacing: 8) {
                            Button {
                                confirm(project, .up)
                            } label: { Label(L10n.t("Start"), systemImage: "play.fill") }
                            Button {
                                confirm(project, .restart)
                            } label: { Label(L10n.t("Restart"), systemImage: "arrow.clockwise") }
                            Button(role: .destructive) {
                                confirm(project, .down)
                            } label: { Label(L10n.t("Stop"), systemImage: "stop.fill") }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 6)
                }

                if filtered.isEmpty && !isLoading && errorMessage == nil {
                    VStack(spacing: 10) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        Text(searchText.isEmpty
                             ? L10n.t("No Compose projects")
                             : L10n.t("No matching Compose projects"))
                            .foregroundStyle(.secondary)
                        Text(L10n.t("Projects started with docker compose appear here. Legacy docker-compose or an outdated Docker version may not be detected."))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
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
