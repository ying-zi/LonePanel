import SwiftUI

/// 容器详情「调用态」：供其它模块（如网站反代关联容器、编排详情跳转）经
/// ModuleCoordinator.openContainerDetail 唤起。
///
/// 调用方只持有一个容器 ID，不引用容器模块的任何视图/模型——本视图按 ID 在
/// **当前服务器**上拉取真实容器，再复用入口态同一个 ContainerDetailView，
/// 保证"入口态 / 调用态"视觉与手势完全一致（用户反复强调的统一原则）。
///
/// 与入口态的严格隔离：
/// - 用独立的 ContainerListModel 实例，绝不触碰 shared，关闭即释放；
/// - 不注入设置入口（齿轮自动隐藏），不改写全局偏好；
/// - 加载走 DockerSSHConnection（其 epoch 校验保证连向当前服务器，见 ServerSession.connectionEpoch），
///   因此网站模块里点开的容器一定是当前服务器上的那一个，不会串到旧机器。
struct ContainerCallView: View {
    let target: ModuleCoordinator.ContainerOpenTarget

    @StateObject private var model = ContainerListModel()
    @State private var loadedContainer: DockerContainer?
    @State private var loadError: String?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView(L10n.t("Loading container..."))
                } else if let error = loadError {
                    ContentUnavailableView {
                        Label(L10n.t("Container unavailable"), systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button(L10n.t("Retry")) { Task { await load() } }
                    }
                } else if let container = loadedContainer {
                    // 复用入口态同一个详情视图：操作、日志、终端入口全部一致。
                    ContainerDetailView(container: container, model: model)
                } else {
                    ContentUnavailableView {
                        Label(L10n.t("Container not found"), systemImage: "shippingbox")
                    } description: {
                        Text(L10n.f("The container \"%@\" no longer exists on this server.", String(describing: (target.title))))
                    }
                }
            }
            .navigationTitle(target.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    DismissChevronButton()
                }
            }
            .task { await load() }
            // 调用态也绑定当前服务器：切服后重新定位容器，避免展示旧机器残留。
            .onReceive(AppEventBus.shared.serverChanges()) { _ in
                loadedContainer = nil
                Task { await load() }
            }
        }
    }

    /// 在当前服务器上刷新容器列表并按 ID 定位。按 ID 而非索引，确保联动目标精确。
    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        await model.refresh()
        if let error = model.errorMessage {
            loadError = error
            return
        }
        loadedContainer = model.containers.first { $0.id == target.containerID }
    }
}
