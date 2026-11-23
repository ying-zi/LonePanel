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
        if currentServer != newCurrent { currentServer = newCurrent }
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
