import SwiftUI

/// 容器详情页：四按钮操作区 + 基本信息 + 端口/卷/网络 + 日志/终端入口。
struct ContainerDetailView: View {
    let container: DockerContainer
    @ObservedObject var model: ContainerListModel
    @Environment(\.dismiss) private var dismiss

    @State private var inspectInfo: DockerInspectInfo?
    @State private var processes: [DockerProcess] = []
    @State private var acting = false
    @State private var showLogs = false
    @State private var terminalSession: TerminalSession?
    @State private var confirmRemove = false
    @State private var confirmKill = false

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
                Section("资源占用") {
                    HStack(spacing: 24) {
                        UsageRing(value: container.usage.cpuPercent, label: "CPU")
                        UsageRing(value: container.usage.memPercent, label: "内存", tint: .purple)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    Label(container.usage.memoryText, systemImage: "memorychip")
                        .font(.subheadline)
                    // 1Panel 统计页核心指标：下行/上行、磁盘读写、进程数。
                    if !container.usage.netIO.isEmpty {
                        InfoRow(title: "网络 (收/发)", value: container.usage.netIO)
                    }
                    if !container.usage.blockIO.isEmpty {
                        InfoRow(title: "磁盘 (读/写)", value: container.usage.blockIO)
                    }
                    if !container.usage.pids.isEmpty {
                        InfoRow(title: "进程数", value: container.usage.pids)
                    }
                }
            }

            // 入口：日志（docker logs 读落盘历史，停止/暂停态仍可查）与终端（需 running）。
            Section {
                Button {
                    showLogs = true
                } label: {
                    Label("容器日志", systemImage: "doc.text.magnifyingglass")
                }
                Button {
                    openContainerTerminal()
                } label: {
                    Label("连接终端", systemImage: "terminal")
                }
                .disabled(container.state != .running)
            } footer: {
                if container.state == .paused {
                    Text("容器已暂停，docker exec 无法进入；恢复运行后可连接终端。日志仍可查看历史输出。")
                } else if container.state == .stopped {
                    Text("容器已停止，启动后可连接终端；日志仍可查看历史输出。")
                }
            }

            // 进程列表（docker top）
            if container.state == .running && !processes.isEmpty {
                Section("进程（\(processes.count)）") {
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
            Section("基本信息") {
                InfoRow(title: "状态", value: container.statusText)
                InfoRow(title: "镜像", value: container.image)
                if let info = inspectInfo, !info.restartPolicy.isEmpty, info.restartPolicy != "no" {
                    InfoRow(title: "重启策略", value: info.restartPolicy)
                }
                if let info = inspectInfo, !info.created.isEmpty {
                    InfoRow(title: "创建时间", value: formatCreated(info.created))
                }
                if let info = inspectInfo, !info.network.isEmpty {
                    InfoRow(title: "网络", value: info.network)
                }
                if !container.command.isEmpty {
                    InfoRow(title: "启动命令", value: container.command)
                }
            }

            // 端口映射
            if let info = inspectInfo, !info.portBindings.isEmpty {
                Section("端口映射") {
                    ForEach(info.portBindings, id: \.container) { binding in
                        InfoRow(title: binding.container, value: binding.host.isEmpty ? "未发布" : binding.host)
                    }
                }
            } else if container.state != .stopped && !container.portsText.isEmpty {
                Section("端口映射") {
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
                            ModuleCoordinator.shared.openFiles(
                                at: mount.source,
                                title: "\(container.name) · \(mount.destination)"
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
                    Text("卷挂载")
                } footer: {
                    Text("点按任意挂载点，调用文件模块打开该目录（只读浏览）。")
                }
            }

            // 环境变量
            if let info = inspectInfo, !info.env.isEmpty {
                Section("环境变量（\(info.env.count)）") {
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
                        Label("强制停止", systemImage: "bolt.fill")
                    }
                }
                Button(role: .destructive) {
                    confirmRemove = true
                } label: {
                    Label("删除容器", systemImage: "trash")
                }
            } header: {
                Text("危险操作")
            } footer: {
                Text("强制停止相当于 docker kill，删除会移除容器及其可写层，均不可撤销。")
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
        .alert("强制停止容器", isPresented: $confirmKill) {
            Button("取消", role: .cancel) {}
            Button("强制停止", role: .destructive) {
                Task {
                    _ = await model.service.killContainer(container.id)
                    await model.refresh()
                    dismiss()
                }
            }
        } message: {
            Text("将立即终止容器内所有进程（docker kill），未保存的数据可能丢失。")
        }
        .alert("删除容器", isPresented: $confirmRemove) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                Task {
                    _ = await model.service.removeContainer(container.id)
                    await model.refresh()
                    dismiss()
                }
            }
        } message: {
            Text("确定删除容器「\(container.name)」吗？此操作不可撤销。")
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
                StatusAction(title: "停止", systemImage: "stop.fill", color: .orange) {
                    await service.stopContainer(id)
                },
                StatusAction(title: "暂停", systemImage: "pause.fill", color: .yellow) {
                    await service.pauseContainer(id)
                },
                StatusAction(title: "重启", systemImage: "arrow.clockwise", color: .blue) {
                    await service.restartContainer(id)
                },
            ]
        case .paused:
            return [
                StatusAction(title: "恢复", systemImage: "play.fill", color: .green) {
                    await service.unpauseContainer(id)
                },
                StatusAction(title: "重启", systemImage: "arrow.clockwise", color: .blue) {
                    await service.restartContainer(id)
                },
            ]
        case .stopped:
            return [
                StatusAction(title: "启动", systemImage: "play.fill", color: .green) {
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
                _ = await action()
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

/// 详情页信息行。
private struct InfoRow: View {
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
