import SwiftUI

/// Docker 模块主视图：顶部分段切换 容器 / 镜像 / Compose。
/// 右上角统一为「搜索 + 更多」，与文件模块一致：搜索由容器列表的 .searchable 提供，
/// 新建容器 / 视图切换 / 诊断收进「更多」，避免多个按钮挤宽导航栏。详情页走 NavigationStack 推入。
struct DockerView: View {
    enum Section: String, CaseIterable {
        case containers = "容器"
        case images = "镜像"
        case compose = "Compose"
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
                }
            }
            .navigationDestination(for: DockerContainer.self) { container in
                ContainerDetailView(container: container, model: containerModel)
            }
            .navigationTitle("Docker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 标题位置的分段控件：容器 / 镜像 / Compose
                ToolbarItem(placement: .principal) {
                    Picker("模块", selection: $section) {
                        ForEach(Section.allCases, id: \.self) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }

                // 更多操作：与文件模块统一，右上角只保留系统搜索放大镜 + 本「更多」菜单。
                // 视图切换 / 新建容器 / 诊断全部收进这里，避免多个按钮挤宽导航栏。
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if section == .containers {
                            Button {
                                showCreate = true
                            } label: {
                                Label("新建容器", systemImage: "plus")
                            }
                            Button {
                                withAnimation {
                                    containerModel.viewMode = (containerModel.viewMode == .cards) ? .list : .cards
                                }
                            } label: {
                                Label(containerModel.viewMode == .cards ? "列表视图" : "卡片视图",
                                      systemImage: containerModel.viewMode == .cards ? "list.bullet" : "square.grid.2x2")
                            }
                            Divider()
                        }
                        // 诊断：查看最近 Docker 命令的退出码与原始输出，排查连接/权限问题。
                        Button {
                            showDiagnostics = true
                            copied = false
                        } label: {
                            Label("诊断", systemImage: "ladybug")
                        }
                    } label: {
                        // 与文件模块一致：系统文件 App 的更多按钮是裸三点，不套圆圈。
                        Image(systemName: "ellipsis")
                            .font(.title3)
                    }
                }

                // 设置入口：并入本模块导航栏 trailing，由系统与「更多」统一排布。
                // 入口态（单模块全屏）才出现；多模块形态与调用态下自动隐藏。
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

    /// 诊断面板：展示命令历史原文，支持一键复制。
    private var diagnosticsSheet: some View {
        NavigationStack {
            Group {
                if diagnostics.entries.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "ladybug")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        Text("尚无命令记录，请先进入容器或镜像页面刷新一次。")
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
            .navigationTitle("Docker 诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        UIPasteboard.general.string = diagnostics.report
                        copied = true
                    } label: {
                        Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showDiagnostics = false }
                }
            }
        }
        .presentationDetents([.large])
    }
}
