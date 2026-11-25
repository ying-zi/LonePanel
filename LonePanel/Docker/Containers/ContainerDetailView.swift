import SwiftUI

/// 容器详情页：四按钮操作区 + 基本信息 + 端口/卷/网络 + 日志/终端入口。
struct ContainerDetailView: View {
    let container: DockerContainer
    @ObservedObject var model: ContainerListModel
    @Environment(\.dismiss) private var dismiss

    @State private var inspectInfo: DockerInspectInfo?
    @State private var acting = false
    @State private var showLogs = false
    @State private var terminalSession: TerminalSession?

    var body: some View {
        List {
            // 顶部：名称 + 状态 + 四按钮
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

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        actionButton("启动", systemImage: "play.fill", color: .green) {
                            await model.service.startContainer(container.id)
                        }
                        .disabled(container.state == .running)

                        actionButton("停止", systemImage: "pause.fill", color: .orange) {
                            await model.service.stopContainer(container.id)
                        }
                        .disabled(container.state != .running)

                        actionButton("重启", systemImage: "arrow.clockwise", color: .blue) {
                            await model.service.restartContainer(container.id)
                        }

                        if container.state == .paused {
                            actionButton("恢复", systemImage: "play.fill", color: .green) {
                                await model.service.unpauseContainer(container.id)
                            }
                        } else {
                            actionButton("暂停", systemImage: "pause.circle", color: .yellow) {
                                await model.service.pauseContainer(container.id)
                            }
                            .disabled(container.state != .running)
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
                }
            }

            // 入口
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
            }

            // 基本信息
            Section("基本信息") {
                InfoRow(title: "状态", value: container.statusText)
                InfoRow(title: "镜像", value: container.image)
                if let info = inspectInfo {
                    if !info.created.isEmpty {
                        InfoRow(title: "创建时间", value: formatCreated(info.created))
                    }
                    if !info.restartPolicy.isEmpty && info.restartPolicy != "no" {
                        InfoRow(title: "重启策略", value: info.restartPolicy)
                    }
                    if !info.network.isEmpty {
                        InfoRow(title: "网络", value: info.network)
                    }
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

            // 卷挂载
            if let info = inspectInfo, !info.mounts.isEmpty {
                Section("卷挂载") {
                    ForEach(info.mounts, id: \.destination) { mount in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(mount.destination)
                                .font(.subheadline)
                            Text(mount.source)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
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
        }
        .navigationTitle(container.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let result = await model.service.fetchInspect(containerID: container.id),
               case .success(let json) = result {
                inspectInfo = DockerInspectInfo.parse(json)
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
        .overlay {
            if acting {
                ProgressView()
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: - 操作按钮

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
        // 独立会话：带 PTY 执行 docker exec，退出不重连、不触碰全局 SSH 连接。
        terminalSession = TerminalSession(execCommand: command, autoReconnect: false)
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
