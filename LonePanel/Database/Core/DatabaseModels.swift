import Foundation

// MARK: - 数据库类型

/// 支持的数据库客户端类型。客户端运行在 SSH 服务器上，App 只负责下发命令与解析输出。
enum DatabaseKind: String, Codable, CaseIterable, Identifiable {
    case mysql
    case postgresql
    case mongodb
    case redis

    var id: String { rawValue }

    /// 展示名称。
    var title: String {
        switch self {
        case .mysql: return "MySQL / MariaDB"
        case .postgresql: return "PostgreSQL"
        case .mongodb: return "MongoDB"
        case .redis: return "Redis"
        }
    }

    /// 客户端可执行文件名（优先）；探测与命令均基于此。
    var clientCommand: String {
        switch self {
        case .mysql: return "mysql"
        case .postgresql: return "psql"
        case .mongodb: return "mongosh"
        case .redis: return "redis-cli"
        }
    }

    /// MongoDB 老版本客户端名，mongosh 不存在时回退。
    var legacyClientCommand: String? {
        self == .mongodb ? "mongo" : nil
    }

    /// 默认端口。
    var defaultPort: Int {
        switch self {
        case .mysql: return 3306
        case .postgresql: return 5432
        case .mongodb: return 27017
        case .redis: return 6379
        }
    }

    /// SF Symbol 图标。
    var symbolName: String {
        switch self {
        case .mysql: return "cylinder"
        case .postgresql: return "cylinder.split.1x2"
        case .mongodb: return "leaf"
        case .redis: return "bolt"
        }
    }

    /// 该类型是否属于"表结构"数据库（有库→表→数据三层）。
    /// Redis 是键值库、MongoDB 是库→集合，走各自的浏览逻辑。
    var supportsSQL: Bool {
        self == .mysql || self == .postgresql
    }
}

// MARK: - 连接配置

/// 一条数据库连接配置。密码不落在这里，只存钥匙串索引键。
struct DatabaseConnection: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var kind: DatabaseKind
    var host: String
    var port: Int
    var username: String
    /// 默认数据库；MongoDB 用作 authSource，Redis 不用。
    var database: String
    /// 钥匙串索引键（密码/URI 口令存这里）。
    var credentialKey: String

    init(
        id: UUID = UUID(),
        name: String,
        kind: DatabaseKind,
        host: String = "127.0.0.1",
        port: Int? = nil,
        username: String = "",
        database: String = "",
        credentialKey: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "127.0.0.1" : host
        self.port = port ?? kind.defaultPort
        self.username = username
        self.database = database
        self.credentialKey = credentialKey ?? "db.credential.\(id.uuidString)"
    }

    /// 展示用连接地址。
    var endpoint: String {
        "\(host):\(port)"
    }
}

// MARK: - 连接配置存储

/// 数据库连接的本地存储。只保存配置元数据，密码存钥匙串。
final class DatabaseConnectionStore: ObservableObject {
    static let shared = DatabaseConnectionStore()

    private let store = UserDefaults.standard
    private let listKey = "com.lone.lonepanel.database.connections"

    @Published private(set) var connections: [DatabaseConnection] = []

    private init() {
        load()
    }

    private func load() {
        guard let data = store.data(forKey: listKey),
              let decoded = try? JSONDecoder().decode([DatabaseConnection].self, from: data) else {
            connections = []
            return
        }
        connections = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(connections) else { return }
        store.set(data, forKey: listKey)
    }

    @discardableResult
    func add(_ connection: DatabaseConnection, password: String) -> Bool {
        do {
            if !password.isEmpty {
                try KeychainStore.save(password, for: connection.credentialKey)
            }
        } catch {
            return false
        }
        connections.append(connection)
        persist()
        return true
    }

    @discardableResult
    func update(_ connection: DatabaseConnection, password: String?) -> Bool {
        guard let idx = connections.firstIndex(where: { $0.id == connection.id }) else { return false }
        if let password, !password.isEmpty {
            do { try KeychainStore.save(password, for: connection.credentialKey) } catch { return false }
        }
        connections[idx] = connection
        persist()
        return true
    }

    func delete(_ connection: DatabaseConnection) {
        connections.removeAll { $0.id == connection.id }
        KeychainStore.delete(connection.credentialKey)
        persist()
    }

    func password(for connection: DatabaseConnection) -> String {
        (try? KeychainStore.load(connection.credentialKey)) ?? ""
    }
}

// MARK: - 可用性探测结果

enum DatabaseAvailability {
    case available(clientVersion: String)
    case clientMissing
    case failed(String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

// MARK: - 查询结果

/// 统一的表格结果：列头 + 行数据。命令型操作（建库/改数据）rows 为空，message 给出反馈。
struct QueryResult: Identifiable {
    let id = UUID()
    let columns: [String]
    let rows: [[String]]
    let message: String
    let isWriteOperation: Bool

    static let empty = QueryResult(columns: [], rows: [], message: "", isWriteOperation: false)
}

// MARK: - 数据库错误

enum DatabaseError: LocalizedError {
    case notConnected(String)
    case commandFailed(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected(let message), .commandFailed(let message), .parseFailed(let message):
            return message
        }
    }
}

// MARK: - 字典项（库 / 表 / 集合 / Key）

/// 数据库浏览的通用列表项：库名、表名、集合名、Redis key 都用它。
struct DatabaseItem: Identifiable, Hashable {
    let id: String
    let name: String
    /// 附加信息（如表行数、key 类型），可为 nil。
    let detail: String?

    init(name: String, detail: String? = nil) {
        self.id = name
        self.name = name
        self.detail = detail
    }
}
