import SwiftUI

/// 容器列表页：顶部分段由父级 DockerView 提供，本页负责容器筛选/搜索/双视图。
struct ContainerListView: View {
    @ObservedObject var model: ContainerListModel
    let onOpenContainer: (DockerContainer) -> Void

    @State private var moreContainer: DockerContainer?
    @State private var confirmRemove: DockerContainer?
    @State private var logsContainer: DockerContainer?
    @State private var confirmKill: DockerContainer?

    var body: some View {
        ZStack {
            List {
                // 探测异常只作为顶部提示，不再阻断容器列表——照常尝试拉数据并显示真实结果。
                availabilityWarning
                contentSections
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))

            if model.isLoading && model.containers.isEmpty {
                ProgressView(L10n.t("Loading containers…"))
            }
        }
        .searchable(text: $model.searchText, prompt: Text(L10n.t("Search container name or image")))
        // 与文件模块统一：未聚焦时收缩为放大镜按钮，点击展开搜索框，工具栏保持干净。
        .searchToolbarBehavior(.minimize)
        .refreshable { await model.refresh() }
        .task { await model.load() }
        .sheet(item: $moreContainer) { container in
            containerMoreSheet(container)
                .presentationDetents([.medium])
        }
        .sheet(item: $logsContainer) { container in
            ContainerLogsView(containerID: container.id, containerName: container.name)
        }
        .alert(L10n.t("Force stop container"), isPresented: Binding(
            get: { confirmKill != nil },
            set: { if !$0 { confirmKill = nil } }
        )) {
            Button(L10n.t("Cancel"), role: .cancel) { confirmKill = nil }
            Button(L10n.t("Force stop"), role: .destructive) {
                if let container = confirmKill {
                    Task {
                        _ = await model.service.killContainer(container.id)
                        await model.refresh()
                    }
                    confirmKill = nil
                }
            }
        } message: {
            Text(L10n.f("Force stopping \"%@\" equals docker kill. Processes are terminated immediately and unsaved data may be lost. Use only if the container is unresponsive.", String(describing: (confirmKill?.name ?? ""))))
        }
        .alert(L10n.t("Remove Container"), isPresented: Binding(
            get: { confirmRemove != nil },
            set: { if !$0 { confirmRemove = nil } }
        )) {
            Button(L10n.t("Cancel"), role: .cancel) { confirmRemove = nil }
            Button(L10n.t("Delete"), role: .destructive) {
                if let container = confirmRemove {
                    Task {
                        _ = await model.service.removeContainer(container.id)
                        await model.refresh()
                    }
                    confirmRemove = nil
                }
            }
        } message: {
            Text(L10n.f("Remove container \"%@\"? This cannot be undone.", String(describing: (confirmRemove?.name ?? ""))))
        }
    }

    // MARK: - 内容区

    private var contentSections: some View {
        Group {
            Section {
                overviewBar
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                if let error = model.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if model.filteredContainers.isEmpty && !model.isLoading {
                    emptyView
                }

                switch model.viewMode {
                case .cards:
                    ForEach(model.filteredContainers) { container in
                        ContainerCard(
                            container: container,
                            model: model,
                            onOpen: { onOpenContainer(container) },
                            onLogs: { logsContainer = container },
                            onMore: { moreContainer = container }
                        )
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                case .list:
                    ForEach(model.filteredContainers) { container in
                        ContainerListRow(
                            container: container,
                            model: model,
                            onOpen: { onOpenContainer(container) },
                            onMore: { moreContainer = container }
                        )
                        .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
            }
        }
    }

    /// 全局状态概览：打开页面第一眼就知道整体健康度（运行/暂停/停止），点按直达对应筛选。
    /// 这是工具类 App「打开即看全貌」的核心——同类监控 App（ServerBox / Beszel）共识。
    private var overviewBar: some View {
        HStack(spacing: 10) {
            overviewCell(count: model.count(for: .running), title: L10n.t("Running"), color: .green, filter: .running)
            overviewCell(count: model.count(for: .paused), title: L10n.t("Paused"), color: .orange, filter: .paused)
            overviewCell(count: model.count(for: .stopped), title: L10n.t("Stopped"), color: .gray, filter: .stopped)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func overviewCell(count: Int, title: String, color: Color, filter: ContainerFilter) -> some View {
        Button {
            withAnimation { model.filter = (model.filter == filter) ? .all : filter }
        } label: {
            VStack(spacing: 4) {
                HStack(spacing: 3) {
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                    Text("\(count)")
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(.primary)
                }
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(model.filter == filter ? color.opacity(0.6) : Color.clear, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "shippingbox")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            if model.searchText.isEmpty {
                Text(L10n.t("No containers"))
                    .foregroundStyle(.secondary)
            } else {
                Text(L10n.t("No matching containers"))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - 更多操作

    private func containerMoreSheet(_ container: DockerContainer) -> some View {
        NavigationStack {
            List {
                Section {
                    if container.state != .running {
                        Button {
                            Task { _ = await model.service.startContainer(container.id); await model.refresh() }
                            moreContainer = nil
                        } label: { Label(L10n.t("Start"), systemImage: "play.fill") }
                    }
                    if container.state == .running {
                        Button {
                            Task { _ = await model.service.stopContainer(container.id); await model.refresh() }
                            moreContainer = nil
                        } label: { Label(L10n.t("Stop"), systemImage: "pause.fill") }
                    }
                    if container.state == .paused {
                        Button {
                            Task { _ = await model.service.unpauseContainer(container.id); await model.refresh() }
                            moreContainer = nil
                        } label: { Label(L10n.t("Resume"), systemImage: "play.fill") }
                    }
                    Button {
                        Task { _ = await model.service.restartContainer(container.id); await model.refresh() }
                        moreContainer = nil
                    } label: { Label(L10n.t("Restart"), systemImage: "arrow.clockwise") }
                    .disabled(container.state == .stopped)
                }

                Section {
                    Button {
                        moreContainer = nil
                        logsContainer = container
                    } label: { Label(L10n.t("View logs"), systemImage: "doc.text.magnifyingglass") }
                    if container.state == .running {
                        Button {
                            moreContainer = nil
                            confirmKill = container
                        } label: { Label(L10n.t("Force stop"), systemImage: "bolt.fill") }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        moreContainer = nil
                        confirmRemove = container
                    } label: { Label(L10n.t("Remove Container"), systemImage: "trash") }
                }
            }
            .navigationTitle(container.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { moreContainer = nil } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .accessibilityLabel(L10n.t("Close"))
                }
            }
        }
    }

    // MARK: - 可用性提示

    /// 顶部警告条：仅当探测判定异常时出现；用 if case 判断（ViewBuilder 不支持 switch）。
    @ViewBuilder
    private var availabilityWarning: some View {
        if let availability = model.availability {
            if case .notInstalled = availability {
                availabilityBanner(title: availabilityTitle(.notInstalled), message: availabilityMessage(.notInstalled))
            } else if case .permissionDenied = availability {
                availabilityBanner(title: availabilityTitle(.permissionDenied), message: availabilityMessage(.permissionDenied))
            } else if case .failed(let message) = availability {
                availabilityBanner(title: availabilityTitle(.failed(message)), message: message)
            }
        }
    }

    /// 行内提示条：探测异常时提示，但不遮挡下方的容器数据与错误信息。
    private func availabilityBanner(title: String, message: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(title).font(.subheadline.weight(.semibold))
                }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(L10n.t("Check Again")) {
                    Task { await model.recheck() }
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 4)
        }
    }

    private func availabilityTitle(_ availability: DockerAvailability) -> String {
        switch availability {
        case .notInstalled: return L10n.t("Docker Not Found")
        case .permissionDenied: return L10n.t("Docker Access Denied")
        case .failed: return L10n.t("Detection Failed")
        case .available: return ""
        }
    }

    private func availabilityMessage(_ availability: DockerAvailability) -> String {
        switch availability {
        case .notInstalled:
            return L10n.t("The docker command was not found on the server. LonePanel calls native docker commands over SSH with no server-side panel required, but Docker itself must be installed.")
        case .permissionDenied:
            return L10n.t("The current user cannot access the Docker socket. Add the user to the docker group (sudo usermod -aG docker $USER, then re-login) or check execution permissions in Settings.")
        case .failed(let message):
            return message
        case .available:
            return ""
        }
    }
}
