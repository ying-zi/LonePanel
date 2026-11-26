import Foundation
import SwiftUI

/// 容器列表视图模式，用户从右上角按钮切换，本地记忆。
enum ContainerViewMode: String {
    case cards
    case list
}

/// 容器筛选档位。
enum ContainerFilter: String, CaseIterable {
    case all
    case running
    case paused
    case stopped
}

/// 容器列表的共享状态：容器数据、筛选、搜索、视图模式、加载与错误。
/// 详情页执行操作后通过 refresh() 重新拉取，列表自动更新。
@MainActor
final class ContainerListModel: ObservableObject {
    @Published private(set) var containers: [DockerContainer] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var availability: DockerAvailability?

    @AppStorage("com.lone.lonepanel.docker.viewMode") var viewMode: ContainerViewMode = .cards
    @AppStorage("com.lone.lonepanel.docker.filter") var filter: ContainerFilter = .all
    @Published var searchText = ""

    let service = DockerService.shared

    /// 首次进入与下拉刷新共用：探测可用性 + 拉数据。
    /// 探测失败不再硬阻断——照常拉一次容器列表，让真实错误直接呈现；
    /// 探测结果降级为可选提示，避免因探测命令在特殊权限环境下失败而「一个容器都不显示」。
    func load() async {
        if availability == nil {
            let result = await service.checkAvailability()
            availability = result
        }
        await refresh()
    }

    /// 仅刷新容器数据（操作后 / 下拉刷新）。
    func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            containers = try await service.fetchContainers()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 强制重新探测（设置里 Docker 权限变化后用）。
    func recheck() async {
        availability = nil
        await load()
    }

    // MARK: - 筛选统计（供筛选按钮括号数量）

    func count(for filter: ContainerFilter) -> Int {
        switch filter {
        case .all: return containers.count
        case .running: return containers.filter { $0.state == .running }.count
        case .paused: return containers.filter { $0.state == .paused }.count
        case .stopped: return containers.filter { $0.state == .stopped }.count
        }
    }

    /// 应用搜索 + 状态筛选后的结果。
    var filteredContainers: [DockerContainer] {
        var result = containers
        switch filter {
        case .all: break
        case .running: result = result.filter { $0.state == .running }
        case .paused: result = result.filter { $0.state == .paused }
        case .stopped: result = result.filter { $0.state == .stopped }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            result = result.filter { container in
                container.name.lowercased().contains(query) ||
                container.image.lowercased().contains(query)
            }
        }
        return result
    }

    // MARK: - 快捷操作

    /// 卡片/列表上的主操作：按状态在启动/停止间切换；暂停态为恢复。
    func primaryAction(for container: DockerContainer) async -> Result<Void, DockerError> {
        switch container.state {
        case .running: return await service.stopContainer(container.id)
        case .paused: return await service.unpauseContainer(container.id)
        case .stopped: return await service.startContainer(container.id)
        }
    }

    func primaryActionLabel(for container: DockerContainer) -> String {
        switch container.state {
        case .running: return L10n.t("Stop")
        case .paused: return L10n.t("Resume")
        case .stopped: return L10n.t("Start")
        }
    }

    func restart(_ container: DockerContainer) async -> Result<Void, DockerError> {
        await service.restartContainer(container.id)
    }
}
