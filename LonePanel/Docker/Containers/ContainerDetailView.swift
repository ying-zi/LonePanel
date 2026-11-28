import SwiftUI

/// 容器详情页：按状态收敛的操作区 + 基本信息 + 端口/卷/网络 + 日志/终端入口。
/// 改配置的入口按容器来源分流：
/// - 编排创建的容器（有 com.docker.compose.project 标签）：不提供重建编辑——真相来源是 yml，
///   改配置去「编排」详情页编辑 yml 再 up；在此重建会脱离编排且下次 up 被覆盖。
/// - 非编排容器（docker run 等）：没有 yml 可改，才提供「重建容器」入口，用可视化表单预填
///   当前配置后重建同名容器（重建出来仍是非编排容器，不影响任何 compose 项目）。
/// 想转为编排：统一去「编排模板」页 →「从已有容器创建模板」，本页不再直接生成编排。
struct ContainerDetailView: View {
    let container: DockerContainer
    @ObservedObject var model: ContainerListModel
    @Environment(\.dismiss) private var dismiss

    @State private var inspectInfo: DockerInspectInfo?
    @State private var processes: [DockerProcess] = []
    @State private var acting = false
    @State private var operationError: String?
    @State private var showLogs = false
    @State private var terminalSession: TerminalSession?
    @State private var confirmRemove = false
    @State private var confirmKill = false
    // 重建容器（仅非编排容器）：从 inspect 反向生成预填 spec，sheet 承载可视化表单。
    @State private var editSpec: ContainerEditDraft?
    @State private var isPreparingEdit = false

    var body: some View {
        List {
            // 顶部：名称 + 状态 + 按状态收敛的操作按钮（最多三个）
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(container.name)
                            .font(.title2.weight(.bold))
                        Spacer()
                        StatusBadge(state: container.state)
                    }
                    Text(container.id.prefix(12))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)

                    // 只显示当前状态下真正可用的操作，不再堆一排 disabled 按钮：
                    // 运行中 → 停止 / 暂停 / 重启；暂停中 → 恢复 / 重启；已停止 → 启动。
                    HStack(spacing: 10) {
                        ForEach(0..<statusActions.count, id: \.self) { index in
                            statusButton(at: index)
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(.vertical, 4)
            }

            // 资源概览（运行中）
            if container.state == .running && container.usage.hasData {
                Section(L10n.t("Resource Usage")) {
                    HStack(spacing: 24) {
                        UsageRing(value: container.usage.cpuPercent, label: "CPU")
                        UsageRing(value: container.usage.memPercent, label: L10n.t("Memory"), tint: .purple)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    Label(container.usage.memoryText, systemImage: "memorychip")
                        .font(.subheadline)
                    // 1Panel 统计页核心指标：下行/上行、磁盘读写、进程数。
                    if !container.usage.netIO.isEmpty {
                        InfoRow(title: L10n.t("Network (RX/TX)"), value: container.usage.netIO)
                    }
                    if !container.usage.blockIO.isEmpty {
                        InfoRow(title: L10n.t("Disk (R/W)"), value: container.usage.blockIO)
                    }
                    if !container.usage.pids.isEmpty {
                        InfoRow(title: L10n.t("Process count"), value: container.usage.pids)
                    }
                }
            }

            // 入口：日志（docker logs 读落盘历史，停止/暂停态仍可查）与终端（需 running）。
            Section {
                Button {
                    showLogs = true
                } label: {
                    Label(L10n.t("Container Logs"), systemImage: "doc.text.magnifyingglass")
                }
                Button {
                    openContainerTerminal()
                } label: {
                    Label(L10n.t("Connect Terminal"), systemImage: "terminal")
                }
                .disabled(container.state != .running)
                // 编排容器改配置去编排页改 yml；非编排容器没有 yml 可改，才给重建入口。
                if !container.isComposeManaged {
                    Button {
                        Task { await prepareEdit() }
                    } label: {
                        Label(L10n.t("Recreate container"), systemImage: "square.and.pencil")
                    }
                    .disabled(isPreparingEdit)
                }
            } footer: {
                if container.state == .paused {
                    Text(L10n.t("Container is paused; docker exec is unavailable. Resume it to connect a terminal. Logs still show past output."))
                } else if container.state == .stopped {
                    Text(L10n.t("Container is stopped; start it to connect a terminal. Logs still show past output."))
                }
            }

            // 进程列表（docker top）
            if container.state == .running && !processes.isEmpty {
                Section(L10n.f("Processes (%@)", String(describing: (processes.count)))) {
                    ForEach(processes) { proc in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("PID \(proc.pid)")
                                    .font(.caption.weight(.semibold).monospaced())
                                Spacer()
                                Text(proc.user)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(proc.command)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            // 基本信息
            Section(L10n.t("Basic Info")) {
                InfoRow(title: L10n.t("Status"), value: container.statusText)
                InfoRow(title: L10n.t("Image"), value: container.image)
                if let info = inspectInfo, !info.restartPolicy.isEmpty, info.restartPolicy != "no" {
                    InfoRow(title: L10n.t("Restart Policy"), value: info.restartPolicy)
                }
                if let info = inspectInfo, !info.created.isEmpty {
                    InfoRow(title: L10n.t("Created"), value: formatCreated(info.created))
                }
                if let info = inspectInfo, !info.network.isEmpty {
                    InfoRow(title: L10n.t("Network"), value: info.network)
                }
                if !container.command.isEmpty {
                    InfoRow(title: L10n.t("Startup command"), value: container.command)
                }
            }

            // 端口映射
            if let info = inspectInfo, !info.portBindings.isEmpty {
                Section(L10n.t("Port Bindings")) {
                    ForEach(info.portBindings, id: \.container) { binding in
                        InfoRow(title: binding.container, value: binding.host.isEmpty ? L10n.t("Not published") : binding.host)
                    }
                }
            } else if container.state != .stopped && !container.portsText.isEmpty {
                Section(L10n.t("Port Bindings")) {
                    Text(container.portsText)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            // 卷挂载：点条目调用文件模块（调用态）打开宿主机上的卷目录。
            if let info = inspectInfo, !info.mounts.isEmpty {
                Section {
                    ForEach(info.mounts, id: \.destination) { mount in
                        Button {
                            // 卷挂载点是宿主机真实目录，允许完整文件操作（新建/编辑/删除/上传）。
                            ModuleCoordinator.shared.manageFiles(
                                at: mount.source,
                                title: L10n.f("%@ · %@", String(describing: (container.name)), String(describing: (mount.destination)))
                            )
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(mount.destination)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                    Text(mount.source)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(L10n.t("Volume Mounts"))
                } footer: {
                    Text(L10n.t("Tap any mount to open that directory in the Files module (read-only)."))
                }
            }

            // 环境变量
            if let info = inspectInfo, !info.env.isEmpty {
                Section(L10n.f("Environment Variables (%@)", String(describing: (info.env.count)))) {
                    ForEach(info.env, id: \.self) { env in
                        Text(env)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }

            // 危险操作
            Section {
                if container.state == .running {
                    Button(role: .destructive) {
                        confirmKill = true
                    } label: {
                        Label(L10n.t("Force stop"), systemImage: "bolt.fill")
                    }
                }
                Button(role: .destructive) {
                    confirmRemove = true
                } label: {
                    Label(L10n.t("Remove Container"), systemImage: "trash")
                }
            } header: {
                Text(L10n.t("Dangerous action"))
            } footer: {
                Text(L10n.t("Force stop equals docker kill; remove deletes the container and its writable layer. Neither can be undone."))
            }
        }
        .navigationTitle(container.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            async let inspectTask = model.service.fetchInspect(containerID: container.id)
            async let processesTask = model.service.fetchProcesses(containerID: container.id)
            let inspectResult = await inspectTask
            let processesResult = await processesTask
            if case .success(let json) = inspectResult {
                inspectInfo = DockerInspectInfo.parse(json)
            }
            if case .success(let list) = processesResult {
                processes = list
            }
        }
        .sheet(isPresented: $showLogs) {
            ContainerLogsView(containerID: container.id, containerName: container.name)
        }
        .sheet(item: $terminalSession) { session in
            TerminalView(session: session, title: container.name)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .interactiveDismissDisabled(true)
                .onDisappear { session.closeForContainer() }
        }
        // 重建非编排容器：sheet 承载预填表单；重建成功后刷新并退回列表（ID 已变）。
        .sheet(item: $editSpec) { draft in
            ContainerCreateView(
                editContext: ContainerCreateView.EditContext(
                    originalID: container.id,
                    name: container.name,
                    wasRunning: container.state == .running
                ),
                spec: draft.spec,
                warnings: draft.warnings
            ) { _ in
                await model.refresh()
                dismiss()
            }
        }
        .alert(L10n.t("Force stop container"), isPresented: $confirmKill) {
            Button(L10n.t("Cancel"), role: .cancel) {}
            Button(L10n.t("Force stop"), role: .destructive) {
                Task {
                    let result = await model.service.killContainer(container.id)
                    if case .failure(let error) = result {
                        operationError = error.localizedDescription
                        return   // 失败不 dismiss，保留现场让用户看到错误
                    }
                    await model.refresh()
                    dismiss()
                }
            }
        } message: {
            Text(L10n.t("Immediately terminates all processes in the container (docker kill); unsaved data may be lost."))
        }
        .alert(L10n.t("Remove Container"), isPresented: $confirmRemove) {
            Button(L10n.t("Cancel"), role: .cancel) {}
            Button(L10n.t("Delete"), role: .destructive) {
                Task {
                    let result = await model.service.removeContainer(container.id)
                    if case .failure(let error) = result {
                        operationError = error.localizedDescription
                        return
                    }
                    await model.refresh()
                    dismiss()
                }
            }
        } message: {
            Text(L10n.f("Remove container \"%@\"? This cannot be undone.", String(describing: (container.name))))
        }
        // 统一运维操作错误出口：启动/停止/重启/删除/强制停止失败都在此呈现。
        .alert(L10n.t("Operation failed"), isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button(L10n.t("OK"), role: .cancel) { operationError = nil }
        } message: {
            Text(operationError ?? "")
        }
        .overlay {
            if acting {
                ProgressView()
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: - 操作按钮

    /// 单个状态操作的定义。
    private struct StatusAction {
        let title: String
        let systemImage: String
        let color: Color
        let run: () async -> Result<Void, DockerError>
    }

    /// 按容器状态返回真正可用的操作（最多三个），避免展示一堆 disabled 按钮。
    private var statusActions: [StatusAction] {
        let id = container.id
        let service = model.service
        switch container.state {
        case .running:
            return [
                StatusAction(title: L10n.t("Stop"), systemImage: "stop.fill", color: .orange) {
                    await service.stopContainer(id)
                },
                StatusAction(title: L10n.t("Pause"), systemImage: "pause.fill", color: .yellow) {
                    await service.pauseContainer(id)
                },
                StatusAction(title: L10n.t("Restart"), systemImage: "arrow.clockwise", color: .blue) {
                    await service.restartContainer(id)
                },
            ]
        case .paused:
            return [
                StatusAction(title: L10n.t("Resume"), systemImage: "play.fill", color: .green) {
                    await service.unpauseContainer(id)
                },
                StatusAction(title: L10n.t("Restart"), systemImage: "arrow.clockwise", color: .blue) {
                    await service.restartContainer(id)
                },
            ]
        case .stopped:
            return [
                StatusAction(title: L10n.t("Start"), systemImage: "play.fill", color: .green) {
                    await service.startContainer(id)
                },
            ]
        }
    }

    /// 按索引取状态动作并生成按钮——避免 ViewBuilder 里元组闭包的复杂类型推断。
    private func statusButton(at index: Int) -> some View {
        let item = statusActions[index]
        return actionButton(item.title, systemImage: item.systemImage, color: item.color) {
            await item.run()
        }
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        color: Color,
        action: @escaping () async -> Result<Void, DockerError>
    ) -> some View {
        Button {
            Task {
                acting = true
                defer { acting = false }
                let result = await action()
                if case .failure(let error) = result {
                    operationError = error.localizedDescription
                    return
                }
                await model.refresh()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(color)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 终端

    private func openContainerTerminal() {
        let command = model.service.execCommand(for: container)
        // 复用 Docker 业务这条已验证可用的连接来开 exec 通道——容器列表能刷出数据，
        // 证明这条连接是通的；避免另起 SharedSSHConnection 时可能从未建立/已被断开。
        // 独立 TerminalSession：带 PTY 执行 docker exec，退出不重连、不触碰全局连接。
        terminalSession = TerminalSession(
            connection: DockerSSHConnection.shared,
            execCommand: command,
            autoReconnect: false
        )
    }

    /// 从 inspect 反向生成重建表单预填配置。复用详情页已加载的 inspectInfo，
    /// 缺失时按需再拉一次，失败走统一错误出口。仅非编排容器调用。
    private func prepareEdit() async {
        isPreparingEdit = true
        defer { isPreparingEdit = false }
        var info = inspectInfo
        if info == nil {
            let fetched = await model.service.fetchInspect(containerID: container.id)
            switch fetched {
            case .success(let json): info = DockerInspectInfo.parse(json)
            case .failure(let error): operationError = error.localizedDescription; return
            }
        }
        guard let info else {
            operationError = L10n.t("Could not read container details")
            return
        }
        let draft = ContainerCreateSpec.from(inspect: info)
        editSpec = ContainerEditDraft(spec: draft.spec, warnings: draft.warnings)
    }

    // MARK: - 工具

    private func formatCreated(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso) else { return iso }
        let display = DateFormatter()
        display.dateStyle = .medium
        display.timeStyle = .short
        return display.string(from: date)
    }
}

/// 重建容器的预填草稿：Identifiable 供 .sheet(item:) 使用。
private struct ContainerEditDraft: Identifiable {
    let id = UUID()
    let spec: ContainerCreateSpec
    let warnings: [String]
}

/// 详情页信息行。internal 可见：ComposeProjectDetailView 等同模块视图复用，避免重复定义。
struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
        }
    }
}
