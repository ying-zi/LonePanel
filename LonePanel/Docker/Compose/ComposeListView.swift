import SwiftUI

/// Compose 项目列表页：展示项目与状态，支持 up / down / restart。
struct ComposeListView: View {
    private let service = DockerService.shared

    @State private var projects: [DockerComposeProject] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var actionTarget: DockerComposeProject?
    @State private var pendingAction: DockerService.ComposeAction?

    var body: some View {
        ZStack {
            List {
                if let error = errorMessage {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }

                ForEach(projects) { project in
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
                            } label: { Label("启动", systemImage: "play.fill") }
                            Button {
                                confirm(project, .restart)
                            } label: { Label("重启", systemImage: "arrow.clockwise") }
                            Button(role: .destructive) {
                                confirm(project, .down)
                            } label: { Label("停止", systemImage: "stop.fill") }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 6)
                }

                if projects.isEmpty && !isLoading && errorMessage == nil {
                    VStack(spacing: 10) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        Text("没有 Compose 项目")
                            .foregroundStyle(.secondary)
                        Text("使用 docker compose 启动的项目会显示在这里。旧版 docker-compose 或 Docker 版本过低时可能不显示。")
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
                ProgressView("正在读取 Compose 项目…")
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .alert(alertTitle, isPresented: Binding(
            get: { pendingAction != nil },
            set: { if !$0 { pendingAction = nil } }
        )) {
            Button("取消", role: .cancel) { pendingAction = nil }
            Button("确定") {
                if let project = actionTarget, let action = pendingAction {
                    Task {
                        _ = await service.composeAction(
                            project.name,
                            configFile: project.configFiles,
                            action: action
                        )
                        await load()
                    }
                }
                pendingAction = nil
            }
        } message: {
            Text("确定对「\(actionTarget?.name ?? "")」执行\(actionLabel)吗？Compose 操作会同时影响该项目下的所有容器。")
        }
    }

    private func confirm(_ project: DockerComposeProject, _ action: DockerService.ComposeAction) {
        actionTarget = project
        pendingAction = action
    }

    private var alertTitle: String {
        guard let action = pendingAction else { return "操作确认" }
        switch action {
        case .up: return "启动 Compose 项目"
        case .down: return "停止 Compose 项目"
        case .restart: return "重启 Compose 项目"
        }
    }

    private var actionLabel: String {
        guard let action = pendingAction else { return "" }
        switch action {
        case .up: return "启动"
        case .down: return "停止"
        case .restart: return "重启"
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
