import SwiftUI

/// Docker 模块主视图：容器 / 镜像 / 编排 / 网络 / 存储卷 五个分区。
/// 顶部菜单（分区切换 + 新建容器 + 视图切换 + 诊断）全部收敛到左上角汉堡图标，
/// 避免 5 段 Picker 横排挤不下；标题栏中间暂时预留，后续再安排。
/// 搜索由各列表的 .searchable 提供；设置齿轮（入口态才出现）保留右上角。详情页走 NavigationStack 推入。
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
                // 左上角汉堡：分区切换 + 本模块所有操作收敛于此，横排不再挤。
                // 用 Menu 的 section 分隔，选中分区打勾，符合 iOS 原生习惯。
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        // 分区切换：五个 Section，当前项打勾。
                        SwiftUI.Section {
                            ForEach(Section.allCases, id: \.self) { item in
                                Button {
                                    withAnimation { section = item }
                                } label: {
                                    // 当前分区显示对勾，其余显示各自图标；两者都是 String，无类型歧义。
                                    Label(L10n.t(item.rawValue),
                                          systemImage: section == item ? "checkmark" : sectionSymbol(item))
                                }
                            }
                        } header: {
                            Text(L10n.t("Section"))
                        }

                        // 容器分区专属操作：新建 / 视图切换。
                        if section == .containers {
                            SwiftUI.Section {
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
                            } header: {
                                Text(L10n.t("Container"))
                            }
                        }

                        // 诊断：查看最近 Docker 命令的退出码与原始输出，排查连接/权限问题。
                        SwiftUI.Section {
                            Button {
                                showDiagnostics = true
                                copied = false
                            } label: {
                                Label(L10n.t("Diagnostics"), systemImage: "ladybug")
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.title3)
                    }
                }

                // 设置入口：保留右上角（入口态才出现，有形态判断）；与汉堡分列两侧不冲突。
                ToolbarItem(placement: .topBarTrailing) {
                    SettingsGearButton()
                }
            }
            .sheet(isPresented: $showDiagnostics) {
                diagnosticsSheet
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
                        Text(L10n.t("No command records yet. Open the Containers or Images tab to refresh once."))
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
