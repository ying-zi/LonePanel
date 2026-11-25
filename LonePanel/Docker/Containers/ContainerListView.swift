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
                ProgressView("正在读取容器…")
            }
        }
        .searchable(text: $model.searchText, prompt: "搜索容器名或镜像")
        .refreshable { await model.refresh() }
        .task { await model.load() }
        .sheet(item: $moreContainer) { container in
            containerMoreSheet(container)
                .presentationDetents([.medium])
        }
        .sheet(item: $logsContainer) { container in
            ContainerLogsView(containerID: container.id, containerName: container.name)
        }
        .alert("强制停止容器", isPresented: Binding(
            get: { confirmKill != nil },
            set: { if !$0 { confirmKill = nil } }
        )) {
            Button("取消", role: .cancel) { confirmKill = nil }
            Button("强制停止", role: .destructive) {
                if let container = confirmKill {
                    Task {
                        _ = await model.service.killContainer(container.id)
                        await model.refresh()
                    }
                    confirmKill = nil
                }
            }
        } message: {
            Text("强制停止「\(confirmKill?.name ?? "")」相当于 docker kill，容器内进程会立即被终止，未保存的数据可能丢失。仅在容器无响应时使用。")
        }
        .alert("删除容器", isPresented: Binding(
            get: { confirmRemove != nil },
            set: { if !$0 { confirmRemove = nil } }
        )) {
            Button("取消", role: .cancel) { confirmRemove = nil }
            Button("删除", role: .destructive) {
                if let container = confirmRemove {
                    Task {
                        _ = await model.service.removeContainer(container.id)
                        await model.refresh()
                    }
                    confirmRemove = nil
                }
            }
        } message: {
            Text("确定删除容器「\(confirmRemove?.name ?? "")」吗？此操作不可撤销。")
        }
    }

    // MARK: - 内容区

    private var contentSections: some View {
        Group {
            Section {
                overviewBar
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                filterBar
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
            overviewCell(count: model.count(for: .running), title: "运行中", color: .green, filter: .running)
            overviewCell(count: model.count(for: .paused), title: "暂停中", color: .orange, filter: .paused)
            overviewCell(count: model.count(for: .stopped), title: "已停止", color: .gray, filter: .stopped)
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

    /// 筛选按钮：每档后面括号显示数量。
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ContainerFilter.allCases, id: \.self) { item in
                    Button {
                        withAnimation { model.filter = item }
                    } label: {
                        HStack(spacing: 3) {
                            Text(label(for: item))
                            Text("(\(model.count(for: item)))")
                                .font(.caption2)
                                .opacity(0.75)
                        }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            model.filter == item ? Color.accentColor : Color(.tertiarySystemBackground),
                            in: Capsule()
                        )
                        .foregroundStyle(model.filter == item ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func label(for filter: ContainerFilter) -> String {
        switch filter {
        case .all: return "全部"
        case .running: return "运行中"
        case .paused: return "暂停中"
        case .stopped: return "已停止"
        }
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "shippingbox")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            if model.searchText.isEmpty {
                Text("没有容器")
                    .foregroundStyle(.secondary)
            } else {
                Text("没有匹配的容器")
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
                        } label: { Label("启动", systemImage: "play.fill") }
                    }
                    if container.state == .running {
                        Button {
                            Task { _ = await model.service.stopContainer(container.id); await model.refresh() }
                            moreContainer = nil
                        } label: { Label("停止", systemImage: "pause.fill") }
                    }
                    if container.state == .paused {
                        Button {
                            Task { _ = await model.service.unpauseContainer(container.id); await model.refresh() }
                            moreContainer = nil
                        } label: { Label("恢复", systemImage: "play.fill") }
                    }
                    Button {
                        Task { _ = await model.service.restartContainer(container.id); await model.refresh() }
                        moreContainer = nil
                    } label: { Label("重启", systemImage: "arrow.clockwise") }
                    .disabled(container.state == .stopped)
                }

                Section {
                    Button {
                        moreContainer = nil
                        logsContainer = container
                    } label: { Label("查看日志", systemImage: "doc.text.magnifyingglass") }
                    if container.state == .running {
                        Button {
                            moreContainer = nil
                            confirmKill = container
                        } label: { Label("强制停止", systemImage: "bolt.fill") }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        moreContainer = nil
                        confirmRemove = container
                    } label: { Label("删除容器", systemImage: "trash") }
                }
            }
            .navigationTitle(container.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { moreContainer = nil }
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
                Button("重新检测") {
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
        case .notInstalled: return "未检测到 Docker"
        case .permissionDenied: return "无权访问 Docker"
        case .failed: return "检测失败"
        case .available: return ""
        }
    }

    private func availabilityMessage(_ availability: DockerAvailability) -> String {
        switch availability {
        case .notInstalled:
            return "服务器上未找到 docker 命令。LonePanel 通过 SSH 调用原生 docker 命令，无需在服务端安装任何面板，但服务器本身需要安装 Docker。"
        case .permissionDenied:
            return "当前用户无权访问 Docker socket。请把用户加入 docker 组（sudo usermod -aG docker $USER 后重新登录），或在设置中检查执行权限。"
        case .failed(let message):
            return message
        case .available:
            return ""
        }
    }
}
