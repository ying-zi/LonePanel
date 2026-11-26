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

/// 实例来源：容器内数据库（1Panel 式主管理对象）/ 远程数据库（管理中的一项能力）。
enum DatabaseSource: String, Codable {
    case container
    case remote
}

/// 一条数据库连接配置。密码不落在这里，只存钥匙串索引键。
/// 同时承载两类实例：容器数据库（由 Docker 容器发现，凭据从环境变量读取）+ 远程连接（用户手填）。
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

    /// 实例来源，默认远程以兼容历史持久化数据。
    var source: DatabaseSource = .remote
    /// 容器内实例：目标容器 ID/名称，命令统一走 `docker exec`。
    var containerID: String?
    /// 容器内实例：容器运行状态描述（运行中 / 已暂停 / 已停止）。
    var statusText: String?
    /// 容器内实例：镜像名，用于展示与类型识别。
    var imageName: String?
    /// 容器内实例：从环境变量读到的口令，仅内存态，不写入本地存储/钥匙串。
    var inlinePassword: String?
    /// 容器内实例：探测到的实际客户端命令名（mysql/mariadb/psql/mongosh/mongo/redis-cli）。
    /// 不同镜像可执行文件不同（如 mariadb:11 只有 mariadb 没有 mysql），仅内存态。
    var containerClient: String?

    enum CodingKeys: String, CodingKey {
        case id, name, kind, host, port, username, database, credentialKey
        case source, containerID, statusText, imageName
    }

    init(
        id: UUID = UUID(),
        name: String,
        kind: DatabaseKind,
        host: String = "127.0.0.1",
        port: Int? = nil,
        username: String = "",
        database: String = "",
        credentialKey: String? = nil,
        source: DatabaseSource = .remote,
        containerID: String? = nil,
        statusText: String? = nil,
        imageName: String? = nil,
        inlinePassword: String? = nil,
        containerClient: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "127.0.0.1" : host
        self.port = port ?? kind.defaultPort
        self.username = username
        self.database = database
        self.credentialKey = credentialKey ?? "db.credential.\(id.uuidString)"
        self.source = source
        self.containerID = containerID
        self.statusText = statusText
        self.imageName = imageName
        self.inlinePassword = inlinePassword
        self.containerClient = containerClient
    }

    /// 兼容旧数据的解码：新增字段缺失时用默认值（远程 / 无容器）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(DatabaseKind.self, forKey: .kind)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        username = try c.decode(String.self, forKey: .username)
        database = try c.decode(String.self, forKey: .database)
        credentialKey = try c.decode(String.self, forKey: .credentialKey)
        source = try c.decodeIfPresent(DatabaseSource.self, forKey: .source) ?? .remote
        containerID = try c.decodeIfPresent(String.self, forKey: .containerID)
        statusText = try c.decodeIfPresent(String.self, forKey: .statusText)
        imageName = try c.decodeIfPresent(String.self, forKey: .imageName)
        // inlinePassword / containerClient 不在 CodingKeys 中，故意不解码：仅内存存在。
        inlinePassword = nil
        containerClient = nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(username, forKey: .username)
        try c.encode(database, forKey: .database)
        try c.encode(credentialKey, forKey: .credentialKey)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(containerID, forKey: .containerID)
        try c.encodeIfPresent(statusText, forKey: .statusText)
        try c.encodeIfPresent(imageName, forKey: .imageName)
        // inlinePassword 故意不编码：容器口令只存在于内存。
    }

    /// 展示用连接地址。
    var endpoint: String {
        "\(host):\(port)"
    }

    /// 是否为容器内数据库实例。
    var isContainer: Bool { source == .container && containerID != nil }

    /// 容器内实例是否处于可查询状态。
    var isRunning: Bool {
        guard let statusText else { return true }
        return !statusText.contains("已停止") && !statusText.contains("已暂停")
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
        // 容器内实例：口令来自环境变量，但允许被「重置密码」覆盖。覆盖值走内存 + 钥匙串，
        // 这样改密后当前会话立即生效，下次重新发现容器也不会退回环境变量里的旧密码。
        if let cid = connection.containerID {
            return ContainerCredentialStore.shared.password(
                for: cid, fallback: connection.inlinePassword ?? ""
            )
        }
        return (try? KeychainStore.load(connection.credentialKey)) ?? ""
    }
}

/// 容器内数据库的口令覆盖层。
/// 容器环境变量里的 root 口令是只读的，改密后不会更新；本层按容器 ID 记录用户设置的新口令，
/// 优先内存（当前会话立即生效），并落钥匙串（重启 App / 重新发现容器后仍有效）。
final class ContainerCredentialStore {
    static let shared = ContainerCredentialStore()

    private var overrides: [String: String] = [:]

    private func key(for containerID: String) -> String { "db.container.\(containerID)" }

    func password(for containerID: String, fallback: String) -> String {
        if let value = overrides[containerID] { return value }
        if let saved = try? KeychainStore.load(key(for: containerID)), !saved.isEmpty {
            overrides[containerID] = saved
            return saved
        }
        return fallback
    }

    func set(_ password: String, for containerID: String) {
        overrides[containerID] = password
        try? KeychainStore.save(password, for: key(for: containerID))
    }

    func clear(for containerID: String) {
        overrides[containerID] = nil
        KeychainStore.delete(key(for: containerID))
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
    case notConnected(message: String)
    case commandFailed(message: String)
    case parseFailed(message: String)

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
