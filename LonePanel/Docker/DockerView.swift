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
    @State private var path = NavigationPath()

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
            }
        }
    }
}
