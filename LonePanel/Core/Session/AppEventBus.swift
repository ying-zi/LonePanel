import Foundation
import Combine

/// 系统级事件类型。所有跨模块广播都走这里，新增事件只加一个 case，编译期穷举检查。
/// - serverChanged：当前服务器 / 连接代次变化。所有「按当前服务器加载数据」的视图都应订阅它。
/// - containersChanged：容器状态或列表变化。网站反代、终端等模块将来据此刷新关联视图。
/// 后续网站 / 数据库模块新增联动事件，继续在这里加 case 即可，无需改动总线本身。
enum AppEvent {
    case serverChanged(epoch: Int)
    case containersChanged
    /// 编排部署成功（模板或容器转编排）。DockerView 据此切到编排分区并刷新，避免退回容器详情。
    case composeDeployed
    /// DockerView 右上 ⋯ 请求打开某分区的「新建类」表单。当前分区子视图订阅后弹出自己的 sheet，
    /// 表单的 onDone / toast 仍留在子视图内，避免把创建逻辑上提到父视图。
    case dockerCreateRequest(DockerCreateRequest)
}

/// Docker 各分区的新建类操作，作为 AppEvent 载荷。
/// 与 DockerView 右上 ⋯ 菜单一一对应：只有当前分区的子视图在树里，故只会有一个订阅者响应。
enum DockerCreateRequest {
    case pullImage
    case importImage
    case createNetwork
    case createVolume
}

/// 系统级类型化事件总线（事件钩子的 emit / on 原语）。
///
/// 与 `ModuleCoordinator`（能力钩子的 call 原语）配套，构成完整钩子体系：
/// - `call(...)`：同步「打开某能力」——能力钩子
/// - `emit(_:)` / `onReceive(...)`：异步「某件事发生了」——事件钩子
///
/// 模块只认识事件类型，不依赖发布方 / 订阅方的具体实现，新增联动零耦合，
/// 符合「关入口不关能力」——即使某模块 Tab 未启用，其广播的事件仍可被其他模块订阅。
final class AppEventBus {
    static let shared = AppEventBus()

    private let subject = PassthroughSubject<AppEvent, Never>()

    /// 全部事件流。视图用 `.onReceive` 订阅后按 case 过滤。
    var publisher: AnyPublisher<AppEvent, Never> {
        subject.eraseToAnyPublisher()
    }

    /// 广播事件。统一切到主线程投递，保证订阅者闭包（常直接改 @State）在主线程执行。
    func emit(_ event: AppEvent) {
        if Thread.isMainThread {
            subject.send(event)
        } else {
            DispatchQueue.main.async { self.subject.send(event) }
        }
    }

    /// 只订阅「当前服务器 / 连接代次变化」，输出新的代次值。
    func serverChanges() -> AnyPublisher<Int, Never> {
        publisher.compactMap {
            if case .serverChanged(let epoch) = $0 { return epoch }
            return nil
        }
        .eraseToAnyPublisher()
    }

    /// 只订阅「容器发生变化」。
    func containerChanges() -> AnyPublisher<Void, Never> {
        publisher.compactMap {
            if case .containersChanged = $0 { return () }
            return nil
        }
        .eraseToAnyPublisher()
    }

    /// 只订阅「编排部署成功」。
    func composeDeployments() -> AnyPublisher<Void, Never> {
        publisher.compactMap {
            if case .composeDeployed = $0 { return () }
            return nil
        }
        .eraseToAnyPublisher()
    }

    /// 只订阅「Docker 新建类表单请求」，输出请求类型。
    func dockerCreateRequests() -> AnyPublisher<DockerCreateRequest, Never> {
        publisher.compactMap {
            if case .dockerCreateRequest(let request) = $0 { return request }
            return nil
        }
        .eraseToAnyPublisher()
    }
}
