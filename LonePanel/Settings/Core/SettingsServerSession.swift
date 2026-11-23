import Foundation

/// Settings/Core 中的具体会话实现：持有业务配置，向根 Core 的 ServerSession 提供连接快照。
/// 临时切换只改内存中的 temporaryServerID，永不写入 ServerStore。
final class SettingsServerSession: ServerSessionProviding {
    static let shared = SettingsServerSession()

    private let store = ServerStore.shared
    private var temporaryServerID: UUID?

    private init() {}

    /// 由 SettingsTab 的注册表项在启动时调用；其他模块不认识这个类型。
    static func install() {
        ServerSession.shared.install(shared)
    }

    // MARK: ServerSessionProviding

    var defaultConnection: ServerConnectionInfo? {
        guard let id = store.defaultServerID,
              let server = store.servers.first(where: { $0.id == id }) else { return nil }
        return connection(from: server)
    }

    var currentConnection: ServerConnectionInfo? {
        let targetID = temporaryServerID ?? store.defaultServerID
        guard let server = store.servers.first(where: { $0.id == targetID }) else { return nil }
        return connection(from: server)
    }

    func selectTemporarily(_ id: UUID) {
        guard store.servers.contains(where: { $0.id == id }) else { return }
        temporaryServerID = id
        ServerSession.shared.refresh()
    }

    func resetToDefault() {
        temporaryServerID = nil
        ServerSession.shared.refresh()
    }

    // MARK: 业务操作（仅 Settings 内部使用）

    var servers: [Server] { store.servers }
    var defaultID: UUID? { store.defaultServerID }

    func credentialKey(for id: UUID) -> String {
        "com.lone.lonepanel.server.\(id.uuidString)"
    }

    func upsert(_ server: Server) {
        var list = store.servers
        if let index = list.firstIndex(where: { $0.id == server.id }) {
            list[index] = server
        } else {
            list.append(server)
        }
        let resolvedDefault = store.defaultServerID ?? server.id
        store.save(servers: list, defaultID: resolvedDefault)
        ServerSession.shared.refresh()
    }

    func remove(_ id: UUID) {
        guard let removed = store.servers.first(where: { $0.id == id }) else { return }
        KeychainStore.delete(removed.credentialKey)
        let remaining = store.servers.filter { $0.id != id }
        var resolvedDefault = store.defaultServerID
        if resolvedDefault == id { resolvedDefault = remaining.first?.id }
        if temporaryServerID == id { temporaryServerID = nil }
        store.save(servers: remaining, defaultID: resolvedDefault)
        ServerSession.shared.refresh()
    }

    func setDefault(_ id: UUID) {
        guard store.servers.contains(where: { $0.id == id }) else { return }
        store.save(servers: store.servers, defaultID: id)
        temporaryServerID = nil
        ServerSession.shared.refresh()
    }

    private func connection(from server: Server) -> ServerConnectionInfo {
        ServerConnectionInfo(
            id: server.id,
            name: server.name,
            host: server.host,
            port: server.port,
            username: server.username,
            authKind: server.authKind,
            credentialKey: server.credentialKey
        )
    }
}
