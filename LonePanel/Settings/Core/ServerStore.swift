import Foundation

/// Settings 私有的服务器列表落盘。只包含配置元数据，不含任何凭证。
final class ServerStore {
    static let shared = ServerStore()

    private let defaults: UserDefaults
    private let serversKey = "com.lone.lonepanel.settings.servers.v1"
    private let defaultKey = "com.lone.lonepanel.settings.defaultServer.v1"

    private(set) var servers: [Server] = []
    private(set) var defaultServerID: UUID?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func save(servers: [Server], defaultID: UUID?) {
        self.servers = servers
        self.defaultServerID = defaultID
        if let data = try? JSONEncoder().encode(servers) {
            defaults.set(data, forKey: serversKey)
        }
        if let id = defaultID {
            defaults.set(id.uuidString, forKey: defaultKey)
        } else {
            defaults.removeObject(forKey: defaultKey)
        }
    }

    private func load() {
        if let data = defaults.data(forKey: serversKey),
           let decoded = try? JSONDecoder().decode([Server].self, from: data) {
            servers = decoded
        }
        if let raw = defaults.string(forKey: defaultKey) {
            defaultServerID = UUID(uuidString: raw)
        }
    }
}
