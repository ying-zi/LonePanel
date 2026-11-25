import SwiftUI

/// Docker 模块主视图：顶部分段切换 容器 / 镜像 / Compose。
/// 容器页右上角提供卡片/列表视图切换；详情页走 NavigationStack 推入。
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

                // 视图切换按钮：只在容器页显示，图标指向「切换后的视图」。
                ToolbarItem(placement: .topBarTrailing) {
                    if section == .containers {
                        Button {
                            withAnimation {
                                containerModel.viewMode = (containerModel.viewMode == .cards) ? .list : .cards
                            }
                        } label: {
                            Image(systemName: containerModel.viewMode == .cards ? "list.bullet" : "square.grid.2x2")
                        }
                        .help(containerModel.viewMode == .cards ? "切换到列表视图" : "切换到卡片视图")
                    }
                }

                // 诊断按钮：查看最近 Docker 命令的退出码与原始输出，便于排查连接/权限问题。
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showDiagnostics = true
                        copied = false
                    } label: {
                        Image(systemName: "ladybug.fill")
                    }
                    .help("诊断")
                }
            }
            .sheet(isPresented: $showDiagnostics) {
                diagnosticsSheet
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
