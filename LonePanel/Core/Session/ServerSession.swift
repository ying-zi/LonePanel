import SwiftUI

/// 会话提供者契约。业务实现放在功能模块（Settings/Core）内部，
/// 其他模块只认识这个协议，不依赖任何具体模块。
protocol ServerSessionProviding: AnyObject {
    var defaultConnection: ServerConnectionInfo? { get }
    var currentConnection: ServerConnectionInfo? { get }
    func selectTemporarily(_ id: UUID)
    func resetToDefault()
}

/// 根 Core 唯一暴露的会话单例。
/// - defaultServer：持久化的默认服务器
/// - currentServer：当次 App 生命周期生效的连接，初始等于默认服务器
/// 临时切换只影响 currentServer，不落盘；App 重启后自然回到默认服务器。
final class ServerSession: ObservableObject {
    static let shared = ServerSession()

    @Published private(set) var defaultServer: ServerConnectionInfo?
    @Published private(set) var currentServer: ServerConnectionInfo?

    /// 连接代次：currentServer 每次发生实质变化（临时切换 / 改默认 / 删除 / 编辑当前服务器）
    /// 都自增。这是跨模块连接失效的统一地基：任何持有 SSH / 终端 / SFTP 连接的模块，
    /// 在复用连接前比对自己建连时记下的代次，不一致即判为过期并强制重建。
    /// 后续网站反代→容器详情等联动，也据此保证"打开的是当前服务器的资源"。
    @Published private(set) var connectionEpoch: Int = 0

    private var provider: ServerSessionProviding?

    private init() {}

    /// 由具体的会话实现在启动时注入；未注入时保持空会话，其他模块仍可编译运行。
    func install(_ provider: ServerSessionProviding) {
        self.provider = provider
        refresh()
    }

    /// 同步提供者中的数据到公开状态。
    func refresh() {
        let newDefault = provider?.defaultConnection
        let newCurrent = provider?.currentConnection ?? newDefault
        if defaultServer != newDefault { defaultServer = newDefault }
        // 只有当前服务器快照真正变化才递增代次——仅改默认但当前是临时切换时不误伤。
        if currentServer != newCurrent {
            currentServer = newCurrent
            connectionEpoch &+= 1
        }
    }

    /// 临时切换到指定服务器（仅当前进程有效）。
    func selectTemporarily(_ server: ServerConnectionInfo) {
        provider?.selectTemporarily(server.id)
        refresh()
    }

    /// 回到默认服务器。
    func resetToDefault() {
        provider?.resetToDefault()
        refresh()
    }
}
