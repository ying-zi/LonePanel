import SwiftUI

/// Docker 模块主视图：容器 / 镜像 / 编排 / 网络 / 存储卷 五个分区。
/// 顶部操作逻辑与文件模块完全一致：左边只放「分类」（左上角汉堡做分区切换），
/// 右边只放 ⋯ 更多菜单（新建容器/视图切换/编排模板/诊断全部收进来）+ 设置齿轮，
/// 搜索放大镜由系统 .searchable 提供，不额外平铺任何图标。详情页走 NavigationStack 推入。
struct DockerView: View {
    enum Section: String, CaseIterable {
        case containers = "Container"
        case images = "Image"
        case compose = "Compose"
        case networks = "Network"
        case volumes = "Volume"
    }

    @State private var section: Section = .containers
    @StateObject private var containerModel = ContainerListModel()
    @StateObject private var diagnostics = DockerDiagnostics.shared
    @State private var path = NavigationPath()
    @State private var showDiagnostics = false
    @State private var showCreate = false
    @State private var showTemplate = false
    @State private var showRegistry = false
    @State private var copied = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch section {
                case .containers:
                    ContainerListView(model: containerModel) { container in
                        path.append(container)
                    }
                case .images:
                    ImageView()
                case .compose:
                    ComposeListView()
                case .networks:
                    NetworkListView()
                case .volumes:
                    VolumeListView()
                }
            }
            .navigationDestination(for: DockerContainer.self) { container in
                ContainerDetailView(container: container, model: containerModel)
            }
            .navigationTitle(L10n.t("Docker"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 左上：只放「分类」——五个分区切换，当前项打勾。操作一律不进左边。
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(Section.allCases, id: \.self) { item in
                            Button {
                                withAnimation { section = item }
                            } label: {
                                // 当前分区显示对勾，其余显示各自图标；两者都是 String，无类型歧义。
                                Label(L10n.t(item.rawValue),
                                      systemImage: section == item ? "checkmark" : sectionSymbol(item))
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.title3)
                    }
                }

                // 右上：「操作」区。与文件模块完全一致——不额外平铺任何图标，
                // 所有操作收进 ⋯ 更多菜单，搜索放大镜由系统 .searchable 提供，设置齿轮恒在最右。
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        // 容器分区：新建容器 + 视图切换。
                        if section == .containers {
                            Button {
                                showCreate = true
                            } label: {
                                Label(L10n.t("New container"), systemImage: "plus")
                            }
                            Button {
                                withAnimation {
                                    containerModel.viewMode = (containerModel.viewMode == .cards) ? .list : .cards
                                }
                            } label: {
                                Label(containerModel.viewMode == .cards ? L10n.t("List View") : L10n.t("Card view"),
                                      systemImage: containerModel.viewMode == .cards ? "list.bullet" : "square.grid.2x2")
                            }
                        }
                        // 编排分区：从模板创建。
                        if section == .compose {
                            Button {
                                showTemplate = true
                            } label: {
                                Label(L10n.t("Compose templates"), systemImage: "doc.badge.plus")
                            }
                        }
                        // 镜像分区：拉取 / 从 tar 导入——与网络/卷统一，入口都在右上 ⋯。
                        if section == .images {
                            Button {
                                AppEventBus.shared.emit(.dockerCreateRequest(.pullImage))
                            } label: {
                                Label(L10n.t("Pull image"), systemImage: "arrow.down.circle")
                            }
                            Button {
                                AppEventBus.shared.emit(.dockerCreateRequest(.importImage))
                            } label: {
                                Label(L10n.t("Import image from tar file"), systemImage: "square.and.arrow.down")
                            }
                        }
                        // 网络分区：创建网络。
                        if section == .networks {
                            Button {
                                AppEventBus.shared.emit(.dockerCreateRequest(.createNetwork))
                            } label: {
                                Label(L10n.t("Create network"), systemImage: "plus.circle")
                            }
                        }
                        // 存储卷分区：创建卷。
                        if section == .volumes {
                            Button {
                                AppEventBus.shared.emit(.dockerCreateRequest(.createVolume))
                            } label: {
                                Label(L10n.t("Create volume"), systemImage: "plus.circle")
                            }
                        }
                        Divider()
                        // 仓库 Registry：私有仓库登录/退出。
                        Button {
                            showRegistry = true
                        } label: {
                            Label(L10n.t("Registry"), systemImage: "shippingbox")
                        }
                        // 诊断：查看最近 Docker 命令的退出码与原始输出。
                        Button {
                            showDiagnostics = true
                            copied = false
                        } label: {
                            Label(L10n.t("Diagnostics"), systemImage: "ladybug")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.title3)
                    }
                }

                // 设置入口：恒在最右（入口态才出现，有形态判断）。
                ToolbarItem(placement: .topBarTrailing) {
                    SettingsGearButton()
                }
            }
            .sheet(isPresented: $showDiagnostics) {
                diagnosticsSheet
            }
            .sheet(isPresented: $showRegistry) {
                RegistryView()
            }
            .sheet(isPresented: $showCreate) {
                ContainerCreateView { newID in
                    // 创建成功后刷新列表，并尽量定位到新容器（按 ID 前缀匹配）。
                    await containerModel.refresh()
                    if let container = containerModel.containers.first(where: { newID.hasPrefix($0.id) }) {
                        path.append(container)
                    }
                }
            }
            .sheet(isPresented: $showTemplate) {
                ComposeTemplateView {
                    // 部署成功已广播 containersChanged，ComposeListView 订阅后自行刷新。
                    await containerModel.refresh()
                }
            }
            // 编排部署成功（模板 / 容器转编排）：切到编排分区、清空导航栈（pop 掉容器详情）、
            // 刷新容器。用户直接看到新项目，不退回容器详情。
            .onReceive(AppEventBus.shared.composeDeployments()) { _ in
                path = NavigationPath()
                withAnimation { section = .compose }
                Task { await containerModel.refresh() }
            }
        }
    }

    /// 汉堡菜单里各分区的图标。独立于本地化，纯系统符号名。
    private func sectionSymbol(_ item: Section) -> String {
        switch item {
        case .containers: return "cube.fill"
        case .images: return "photo.stack"
        case .compose: return "square.stack.3d.up"
        case .networks: return "network"
        case .volumes: return "externaldrive"
        }
    }

    /// 诊断面板：展示命令历史原文，支持一键复制。
    private var diagnosticsSheet: some View {
        NavigationStack {
            Group {
                if diagnostics.entries.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "ladybug")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        Text(L10n.t("No command records yet. Open the Containers or Images section to refresh once."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(diagnostics.entries) { entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(entry.time)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text("exit \(entry.exit)")
                                            .foregroundStyle(entry.exit == 0 ? .green : .red)
                                    }
                                    .font(.caption.monospacedDigit())
                                    Text(entry.command)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.tint)
                                        .textSelection(.enabled)
                                    if !entry.out.isEmpty {
                                        Text("out: \(entry.out)")
                                            .font(.caption2.monospaced())
                                            .textSelection(.enabled)
                                    }
                                    if !entry.err.isEmpty {
                                        Text("err: \(entry.err)")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.orange)
                                            .textSelection(.enabled)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle(L10n.t("Docker Diagnostics"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        UIPasteboard.general.string = diagnostics.report
                        copied = true
                    } label: {
                        Label(copied ? L10n.t("Copied") : L10n.t("Copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showDiagnostics = false } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .accessibilityLabel(L10n.t("Close"))
                }
            }
        }
        .presentationDetents([.large])
    }
}
