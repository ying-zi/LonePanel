import Foundation
import SwiftUI

// MARK: - 数据库专用 SSH 连接

/// 数据库业务专用 SSH 连接——与全局终端、Docker 连接物理隔离。
/// 终端保活重连会打断在途命令，独立连接避免库列表/查询被中途掐断。
@MainActor
final class DatabaseSSHConnection: ObservableObject {
    static let shared = DatabaseSSHConnection()

    @Published private(set) var isConnected = false
    @Published private(set) var lastError: String?

    private var session: SSHSession?
    private var privilege: RemotePrivilege = .none
    private var connectTask: Task<Bool, Never>?
    private var connectedServerID: UUID?

    @discardableResult
    func ensureConnected(force: Bool = false) async -> Bool {
        guard let info = ServerSession.shared.currentServer else {
            lastError = "请先到「设置 → 我的服务器」添加并选择一个服务器"
            return false
        }
        if !force, isConnected, connectedServerID == info.id, session != nil { return true }
        if let connectTask { return await connectTask.value }

        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            return await self.performConnect(info: info)
        }
        connectTask = task
        let ok = await task.value
        connectTask = nil
        return ok
    }

    private func performConnect(info: ServerConnectionInfo) async -> Bool {
        isConnected = false
        lastError = nil
        do {
            let secret = try KeychainStore.load(info.credentialKey)
            let credential: SSHAuthCredential
            switch info.authKind {
            case .password: credential = .password(secret)
            case .privateKey: credential = .privateKey(secret)
            }
            let newSession = try await SSHSession(
                host: info.host, port: info.port,
                username: info.username, credential: credential
            )
            let newPrivilege = await Self.detectPrivilege(on: newSession, serverID: info.id)
            session?.close()
            session = newSession
            privilege = newPrivilege
            connectedServerID = info.id
            isConnected = true
            return true
        } catch {
            session?.close()
            session = nil
            isConnected = false
            lastError = SSHSession.describe(error)
            return false
        }
    }

    private static func detectPrivilege(on session: SSHSession, serverID: UUID) async -> RemotePrivilege {
        let cacheKey = "shared.privilege.\(serverID.uuidString)"
        if let cached = UserDefaults.standard.string(forKey: cacheKey),
           let hit = RemotePrivilege(rawValue: cached) { return hit }
        var result: RemotePrivilege = .none
        if let uid = try? await session.execute("id -u", timeoutSeconds: 8),
           uid.exitStatus == 0,
           uid.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "0" {
            result = .root
        } else if let probe = try? await session.execute("sudo -n true", timeoutSeconds: 8),
                  probe.exitStatus == 0 {
            result = .sudo
        }
        UserDefaults.standard.set(result.rawValue, forKey: cacheKey)
        return result
    }

    func run(_ command: String, timeoutSeconds: Int = 30) async throws -> SSHExecResult {
        guard let session else { throw SSHConnectionError.closedUnexpectedly }
        let wrapped = privilege == .sudo ? "sudo -n \(command)" : command
        return try await session.execute(wrapped, timeoutSeconds: timeoutSeconds)
    }

    func disconnect() {
        session?.close()
        session = nil
        isConnected = false
        privilege = .none
        connectedServerID = nil
    }
}

// MARK: - 数据库服务

/// 数据库命令层：全部通过专用 SSH 连接执行服务器上的数据库客户端。
/// 命令构造遵循两点：① 所有外部输入经 shell 引号转义；② 密码走环境变量，不进命令行。
@MainActor
final class DatabaseService {
    static let shared = DatabaseService()

    private let connection = DatabaseSSHConnection.shared
    private let store = DatabaseConnectionStore.shared

    private let listTimeout = 30
    private let queryTimeout = 45

    /// docker ps -a --format '{{json .}}' 的轻量行，只取识别与连接所需字段。
    private struct ContainerRow: Decodable {
        let ID: String
        let Names: String
        let Image: String
        let Status: String
    }

    // MARK: - 容器内数据库发现（1Panel 式主管理对象）

    /// 自动发现服务器 Docker 里的数据库容器，构造可直接查询的容器实例连接。
    /// 凭据从容器环境变量读出（仅内存态），命令统一走 `docker exec`，不依赖端口映射：
    /// 这正是「数据库管理 = 管理容器里的数据库」的落点，远程连接只是其中一种来源。
    func discoverContainerDatabases() async -> Result<[DatabaseConnection], DatabaseError> {
        let listed = await run("docker ps -a --format '{{json .}}'", timeout: listTimeout)
        guard listed.exit == 0 else {
            return .failure(.commandFailed(message: readableError(listed)))
        }
        let rows = decodeLines(ContainerRow.self, listed.out)
        var instances: [DatabaseConnection] = []
        for row in rows {
            guard let kind = Self.kindFromImage(row.Image) else { continue }
            let cid = row.ID
            let envResult = await run(
                "docker inspect \(ShellQuote.quote(cid)) --format '{{range .Config.Env}}{{println .}}{{end}}'",
                timeout: 20
            )
            let env = Self.parseEnv(envResult.out)
            let (user, password, database) = Self.credentials(for: kind, env: env)
            let name = row.Names.split(separator: ",").first.map(String.init) ?? cid
            let instance = DatabaseConnection(
                name: name,
                kind: kind,
                host: "127.0.0.1",
                port: kind.defaultPort,
                username: user,
                database: database,
                source: .container,
                containerID: cid,
                statusText: Self.containerStatus(row.Status),
                imageName: row.Image,
                inlinePassword: password
            )
            instances.append(instance)
        }
        return .success(instances.sorted { lhs, rhs in
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        })
    }

    /// 依据镜像名识别数据库类型，覆盖官方镜像与常见自定义命名。
    private static func kindFromImage(_ image: String) -> DatabaseKind? {
        let s = image.lowercased()
        if s.contains("mariadb") || s.contains("mysql") { return .mysql }
        if s.contains("postgres") { return .postgresql }
        if s.contains("mongo") { return .mongodb }
        if s.contains("redis") { return .redis }
        return nil
    }

    /// 解析 docker inspect 输出的环境变量（KEY=VALUE 逐行）。
    private static func parseEnv(_ text: String) -> [String: String] {
        var env: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            env[pair[0]] = pair[1]
        }
        return env
    }

    /// 各官方镜像的用户 / 口令 / 库环境变量名不同，这里统一归一。
    private static func credentials(for kind: DatabaseKind, env: [String: String]) -> (String, String, String) {
        switch kind {
        case .mysql:
            let user = env["MYSQL_USER"] ?? "root"
            let password = env["MYSQL_PASSWORD"] ?? env["MYSQL_ROOT_PASSWORD"] ?? ""
            return (user, password, env["MYSQL_DATABASE"] ?? "")
        case .postgresql:
            return (env["POSTGRES_USER"] ?? "postgres",
                    env["POSTGRES_PASSWORD"] ?? "",
                    env["POSTGRES_DB"] ?? "postgres")
        case .mongodb:
            return (env["MONGO_INITDB_ROOT_USERNAME"] ?? "",
                    env["MONGO_INITDB_ROOT_PASSWORD"] ?? "",
                    "admin")
        case .redis:
            return ("", env["REDIS_PASSWORD"] ?? "", "0")
        }
    }

    private static func containerStatus(_ status: String) -> String {
        let s = status.lowercased()
        if s.contains("paused") { return "已暂停" }
        if s.hasPrefix("up") { return "运行中" }
        return "已停止"
    }

    /// 逐行 JSON 解码，与 Docker 模块同款格式，但不依赖其模型类型。
    private func decodeLines<T: Decodable>(_ type: T.Type, _ text: String) -> [T] {
        text.split(separator: "\n").compactMap { line in
            guard let data = String(line).data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        }
    }

    // MARK: - 可用性探测

    func checkAvailability(for kind: DatabaseKind) async -> DatabaseAvailability {
        guard await connection.ensureConnected() else {
            return .failed(connection.lastError ?? "连接失败")
        }
        let primary = kind.clientCommand
        let version = await run("\(primary) --version 2>&1 | head -1", timeout: 12)
        if version.exit == 0 && !version.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .available(clientVersion: version.out.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // MongoDB 老版本回退到 mongo。
        if let legacy = kind.legacyClientCommand {
            let legacyResult = await run("\(legacy) --version 2>&1 | head -1", timeout: 12)
            if legacyResult.exit == 0 && !legacyResult.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .available(clientVersion: legacyResult.out.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return .clientMissing
    }

    // MARK: - 库 / 集合 / Key 列表

    /// 列出数据库（MongoDB=库，Redis=有数据的 db 索引）。
    func listDatabases(_ conn: DatabaseConnection) async -> Result<[DatabaseItem], DatabaseError> {
        let command: String
        switch conn.kind {
        case .mysql:
            command = "\(mysqlBase(conn)) -N -B -e \"SHOW DATABASES\" 2>&1"
        case .postgresql:
            command = "\(psqlBase(conn, database: "postgres")) -t -A -c \"SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname\" 2>&1"
        case .mongodb:
            let uri = mongoURI(conn, database: "admin")
            command = "\(mongoClient(conn)) \(ShellQuote.quote(uri)) --quiet --eval \"db.adminCommand('listDatabases').databases.map(function(d){return d.name}).join('\\n')\" 2>&1"
        case .redis:
            command = "\(redisBase(conn)) INFO keyspace 2>&1"
        }

        let result = await runNonEmpty(command, timeout: listTimeout)
        guard result.exit == 0 else {
            return .failure(.commandFailed(message: readableError(result)))
        }
        switch conn.kind {
        case .redis:
            return .success(parseRedisKeyspaces(result.out))
        default:
            return .success(parseLines(result.out))
        }
    }

    /// 列出某个库下的表（MySQL/PostgreSQL）或集合（MongoDB）。
    func listTables(_ conn: DatabaseConnection, database: String) async -> Result<[DatabaseItem], DatabaseError> {
        let command: String
        switch conn.kind {
        case .mysql:
            // mysqlBase 已带 -D database，SHOW TABLES 直接列当前库，避免反引号转义。
            command = "\(mysqlBase(conn)) -N -B -e \"SHOW TABLES\" 2>&1"
        case .postgresql:
            command = "\(psqlBase(conn, database: database)) -t -A -c \"SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename\" 2>&1"
        case .mongodb:
            let uri = mongoURI(conn, database: database)
            command = "\(mongoClient(conn)) \(ShellQuote.quote(uri)) --quiet --eval \"db.getCollectionNames().sort().join('\\n')\" 2>&1"
        case .redis:
            // Redis 不做表层级，直接列 key。
            return await listRedisKeys(conn, pattern: "*")
        }

        let result = await runNonEmpty(command, timeout: listTimeout)
        guard result.exit == 0 else {
            return .failure(.commandFailed(message: readableError(result)))
        }
        return .success(parseLines(result.out))
    }

    /// Redis 按 pattern 扫描 key（SCAN，避免 KEYS 阻塞）。
    func listRedisKeys(_ conn: DatabaseConnection, pattern: String) async -> Result<[DatabaseItem], DatabaseError> {
        let command = "\(redisBase(conn)) --scan --pattern \(ShellQuote.quote(pattern)) 2>&1"
        let result = await run(command, timeout: listTimeout)
        guard result.exit == 0 else {
            return .failure(.commandFailed(message: readableError(result)))
        }
        return .success(parseLines(result.out))
    }

    // MARK: - 数据浏览

    /// 读取表/集合的数据预览（前 100 条）。
    func previewData(_ conn: DatabaseConnection, database: String, table: String) async -> Result<QueryResult, DatabaseError> {
        let safeTable = escapeSQLIdentifier(table)
        let command: String
        switch conn.kind {
        case .mysql:
            // sql 整体用单引号包裹，反引号在里面无需 shell 转义。
            let sql = "SELECT * FROM `\(escapeSQLIdentifier(database))`.`\(safeTable)` LIMIT 100"
            command = "\(mysqlBase(conn)) -B -e \(ShellQuote.quote(sql)) 2>&1"
        case .postgresql:
            let sql = "SELECT * FROM \"\(safeTable)\" LIMIT 100"
            command = "\(psqlBase(conn, database: database)) -c \(ShellQuote.quote(sql)) 2>&1"
        case .mongodb:
            let uri = mongoURI(conn, database: database)
            let js = "JSON.stringify(db.getCollection(\(jsString(table))).find().limit(100).toArray())"
            command = "\(mongoClient(conn)) \(ShellQuote.quote(uri)) --quiet --eval \(ShellQuote.quote(js)) 2>&1"
            return await runMongoJSON(command)
        case .redis:
            return await readRedisValue(conn, key: table)
        }
        return await runTable(command)
    }

    // MARK: - 执行自定义命令 / SQL

    /// 执行用户输入的 SQL（MySQL/PostgreSQL）或原始命令（MongoDB eval / Redis 命令）。
    func execute(_ conn: DatabaseConnection, database: String, statement: String) async -> Result<QueryResult, DatabaseError> {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.commandFailed(message: "请输入要执行的语句")) }

        let command: String
        switch conn.kind {
        case .mysql:
            command = "\(mysqlBase(conn)) -B -e \(ShellQuote.quote(trimmed)) 2>&1"
        case .postgresql:
            command = "\(psqlBase(conn, database: database)) -c \(ShellQuote.quote(trimmed)) 2>&1"
        case .mongodb:
            let uri = mongoURI(conn, database: database.isEmpty ? "admin" : database)
            command = "\(mongoClient(conn)) \(ShellQuote.quote(uri)) --quiet --eval \(ShellQuote.quote(trimmed)) 2>&1"
            return await runMongoEval(command)
        case .redis:
            // 逐行执行多条 redis 命令。
            command = "\(redisBase(conn)) --no-raw \(trimmed) 2>&1"
        }
        return await runTable(command)
    }

    // MARK: - Redis 单值读取

    /// 读取一个 Redis key 的值，按类型选择命令。
    func readRedisValue(_ conn: DatabaseConnection, key: String) async -> Result<QueryResult, DatabaseError> {
        let q = ShellQuote.quote(key)
        let typeResult = await run("\(redisBase(conn)) TYPE \(q) 2>&1", timeout: listTimeout)
        guard typeResult.exit == 0 else {
            return .failure(.commandFailed(message: readableError(typeResult)))
        }
        let type = typeResult.out.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "string:", with: "").lowercased()
        let valueCommand: String
        switch type {
        case "list": valueCommand = "LRANGE \(q) 0 99"
        case "hash": valueCommand = "HGETALL \(q)"
        case "set": valueCommand = "SMEMBERS \(q)"
        case "zset": valueCommand = "ZRANGE \(q) 0 99 WITHSCORES"
        default: valueCommand = "GET \(q)"
        }
        let result = await run("\(redisBase(conn)) --no-raw \(valueCommand) 2>&1", timeout: listTimeout)
        guard result.exit == 0 else {
            return .failure(.commandFailed(message: readableError(result)))
        }
        let lines = result.out.split(separator: "\n").map(String.init)
        let columns = type == "hash" || type == "zset" ? ["字段", "值"] : ["值"]
        var rows: [[String]] = []
        if columns.count == 2 {
            var i = 0
            while i + 1 < lines.count {
                rows.append([lines[i], lines[i + 1]])
                i += 2
            }
        } else {
            rows = lines.map { [$0] }
        }
        return .success(QueryResult(columns: columns, rows: rows,
                                    message: "类型：\(type)", isWriteOperation: false))
    }

    // MARK: - 连接测试

    /// 测试一条连接配置能否真正连上数据库（SELECT 1 / PING）。
    func testConnection(_ conn: DatabaseConnection) async -> Result<String, DatabaseError> {
        let command: String
        switch conn.kind {
        case .mysql: command = "\(mysqlBase(conn)) -N -B -e \"SELECT 1\" 2>&1"
        case .postgresql: command = "\(psqlBase(conn, database: conn.database.isEmpty ? "postgres" : conn.database)) -t -A -c \"SELECT 1\" 2>&1"
        case .mongodb: command = "\(mongoClient(conn)) \(ShellQuote.quote(mongoURI(conn, database: conn.database.isEmpty ? "admin" : conn.database))) --quiet --eval \"db.runCommand({ping:1}).ok\" 2>&1"
        case .redis: command = "\(redisBase(conn)) PING 2>&1"
        }
        let result = await run(command, timeout: 15)
        let out = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.exit == 0 && (out.contains("1") || out.uppercased().contains("PONG")) {
            return .success("连接成功")
        }
        return .failure(.commandFailed(message: readableError(result)))
    }

    // MARK: - 命令构造：各客户端

    private func mysqlBase(_ conn: DatabaseConnection) -> String {
        let password = store.password(for: conn)
        // 容器内实例：docker exec 注入口令，容器内部本地连接，无需端口映射。
        if let cid = conn.containerID {
            var exec = "docker exec"
            if !password.isEmpty { exec += " -e MYSQL_PWD=\(ShellQuote.quote(password))" }
            var cmd = "\(exec) \(ShellQuote.quote(cid)) mysql -u \(ShellQuote.quote(conn.username))"
            if !conn.database.isEmpty { cmd += " -D \(ShellQuote.quote(conn.database))" }
            return cmd
        }
        var parts: [String] = []
        if !password.isEmpty { parts.append("MYSQL_PWD=\(ShellQuote.quote(password))") }
        var cmd = parts.joined(separator: " ")
        cmd += (cmd.isEmpty ? "" : " ") + "mysql -h \(ShellQuote.quote(conn.host)) -P \(conn.port) -u \(ShellQuote.quote(conn.username))"
        if !conn.database.isEmpty { cmd += " -D \(ShellQuote.quote(conn.database))" }
        return cmd
    }

    private func psqlBase(_ conn: DatabaseConnection, database: String) -> String {
        let password = store.password(for: conn)
        if let cid = conn.containerID {
            var exec = "docker exec"
            if !password.isEmpty { exec += " -e PGPASSWORD=\(ShellQuote.quote(password))" }
            return "\(exec) \(ShellQuote.quote(cid)) psql -U \(ShellQuote.quote(conn.username)) -d \(ShellQuote.quote(database))"
        }
        var parts: [String] = []
        if !password.isEmpty { parts.append("PGPASSWORD=\(ShellQuote.quote(password))") }
        var cmd = parts.joined(separator: " ")
        cmd += (cmd.isEmpty ? "" : " ") + "psql -h \(ShellQuote.quote(conn.host)) -p \(conn.port) -U \(ShellQuote.quote(conn.username)) -d \(ShellQuote.quote(database))"
        return cmd
    }

    private func redisBase(_ conn: DatabaseConnection) -> String {
        let password = store.password(for: conn)
        if let cid = conn.containerID {
            var exec = "docker exec"
            if !password.isEmpty { exec += " -e REDISCLI_AUTH=\(ShellQuote.quote(password))" }
            var cmd = "\(exec) \(ShellQuote.quote(cid)) redis-cli"
            if let dbIndex = Int(conn.database) { cmd += " -n \(dbIndex)" }
            return cmd
        }
        var cmd = "REDISCLI_AUTH=\(ShellQuote.quote(password)) redis-cli -h \(ShellQuote.quote(conn.host)) -p \(conn.port)"
        if !conn.database.isEmpty, let dbIndex = Int(conn.database) {
            cmd += " -n \(dbIndex)"
        }
        return cmd
    }

    private func mongoClient(_ conn: DatabaseConnection) -> String {
        // 容器内实例：在容器里跑 mongosh，连接参数由 mongoURI 提供。
        if let cid = conn.containerID {
            return "docker exec \(ShellQuote.quote(cid)) mongosh"
        }
        // 优先 mongosh，回退 mongo（探测阶段已确认可用者）。
        return DatabaseKind.mongodb.clientCommand
    }

    private func mongoURI(_ conn: DatabaseConnection, database: String) -> String {
        let password = store.password(for: conn)
        let user = conn.username
        let host = "\(conn.host):\(conn.port)"
        if user.isEmpty {
            return "mongodb://\(host)/\(database)"
        }
        let encodedUser = uriEncode(user)
        let encodedPass = uriEncode(password)
        let authSource = conn.database.isEmpty ? "admin" : conn.database
        return "mongodb://\(encodedUser):\(encodedPass)@\(host)/\(database)?authSource=\(uriEncode(authSource))"
    }

    // MARK: - 输出解析

    /// 表格型命令输出：第一行是列名，其余是数据（TSV / psql 对齐格式）。
    private func runTable(_ command: String) async -> Result<QueryResult, DatabaseError> {
        let result = await run(command, timeout: queryTimeout)
        // 有错误特征但 exit=0（部分客户端把错误写到 stdout）也要识别。
        let out = result.out
        if result.exit != 0 {
            return .failure(.commandFailed(message: readableError(result)))
        }
        if looksLikeError(out) {
            return .failure(.commandFailed(message: firstMeaningfulLine(out)))
        }
        return .success(parseTable(out))
    }

    /// MongoDB 的 JSON 数组输出 → 表格。
    private func runMongoJSON(_ command: String) async -> Result<QueryResult, DatabaseError> {
        let result = await run(command, timeout: queryTimeout)
        guard result.exit == 0 else {
            return .failure(.commandFailed(message: readableError(result)))
        }
        let out = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.isEmpty { return .success(.empty) }
        guard let data = out.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return .failure(.parseFailed(message: firstMeaningfulLine(out)))
        }
        // 收集所有出现过的键作为列（保持首次出现顺序）。
        var columns: [String] = []
        for dict in array {
            for key in dict.keys where !columns.contains(key) { columns.append(key) }
        }
        let rows = array.map { dict in
            columns.map { key -> String in
                guard let value = dict[key] else { return "" }
                return stringifyJSONValue(value)
            }
        }
        return .success(QueryResult(columns: columns, rows: rows,
                                    message: "\(array.count) 条文档", isWriteOperation: false))
    }

    /// MongoDB eval 输出：JSON / 简单值 / 文本。
    private func runMongoEval(_ command: String) async -> Result<QueryResult, DatabaseError> {
        let result = await run(command, timeout: queryTimeout)
        guard result.exit == 0 else {
            return .failure(.commandFailed(message: readableError(result)))
        }
        let out = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.isEmpty { return .success(.empty) }
        // 尝试当 JSON 数组解析。
        if let data = out.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            var columns: [String] = []
            for dict in array { for key in dict.keys where !columns.contains(key) { columns.append(key) } }
            let rows = array.map { dict in columns.map { key in stringifyJSONValue(dict[key] ?? NSNull()) } }
            return .success(QueryResult(columns: columns, rows: rows,
                                        message: "\(array.count) 条结果", isWriteOperation: false))
        }
        return .success(QueryResult(columns: ["结果"], rows: [[out]],
                                    message: "命令已执行", isWriteOperation: false))
    }

    /// 解析 TSV / psql 表格。
    private func parseTable(_ text: String) -> QueryResult {
        let lines = text.split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first = lines.first else {
            return .successEmpty
        }
        // MySQL -B 用 tab；psql 默认用 '|' 且带分隔线，取第一行非空并按 '|' 拆。
        let separator: Character = first.contains("\t") ? "\t" : "|"
        var columns = first.split(separator: separator).map { cleanCell(String($0)) }
        var dataLines = Array(lines.dropFirst())
        // psql 的 "+---+---+" 分隔线过滤掉；末尾 "(N rows)" 统计行作为 message。
        var message = ""
        dataLines = dataLines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.allSatisfy({ $0 == "+" || $0 == "-" }) { return false }
            if trimmed.hasPrefix("(") && trimmed.contains("row") { message = trimmed; return false }
            return true
        }
        if columns.isEmpty {
            columns = ["结果"]
        }
        let rows = dataLines.map { line in
            line.split(separator: separator, omittingEmptySubsequences: false).map { cleanCell(String($0)) }
        }
        return QueryResult(columns: columns, rows: rows, message: message, isWriteOperation: false)
    }

    /// 按行拆成单列列表。
    private func parseLines(_ text: String) -> [DatabaseItem] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { DatabaseItem(name: $0) }
    }

    /// Redis INFO keyspace → db0, db1 ...（只含有 key 的库）。
    private func parseRedisKeyspaces(_ text: String) -> [DatabaseItem] {
        var items: [DatabaseItem] = []
        for line in text.split(separator: "\n") {
            let s = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("db"), let colon = s.firstIndex(of: ":") {
                let name = String(s[..<colon])
                let detail = String(s[s.index(after: colon)...]).split(separator: ",").first.map(String.init)
                items.append(DatabaseItem(name: name, detail: detail?.trimmingCharacters(in: .whitespaces)))
            }
        }
        if items.isEmpty {
            // 没有 keyspace 信息时至少给出默认 db0 供浏览。
            items.append(DatabaseItem(name: "db0", detail: nil))
        }
        return items
    }

    // MARK: - 执行包装（重连重试）

    private func run(_ command: String, timeout: Int) async -> (out: String, err: String, exit: Int) {
        let first = await executeOnce(command, timeout: timeout)
        guard first.exit < 0 else { return first }
        guard await connection.ensureConnected(force: true) else { return first }
        return await executeOnce(command, timeout: timeout)
    }

    private func runNonEmpty(_ command: String, timeout: Int) async -> (out: String, err: String, exit: Int) {
        var result = await run(command, timeout: timeout)
        var attempts = 0
        while result.exit == 0 &&
              result.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
              attempts < 2 {
            attempts += 1
            result = await run(command, timeout: timeout)
        }
        return result
    }

    private func executeOnce(_ command: String, timeout: Int) async -> (out: String, err: String, exit: Int) {
        do {
            let exec = try await connection.run(command, timeoutSeconds: timeout)
            return (exec.stdout, exec.stderr, Int(exec.exitStatus))
        } catch {
            return ("", SSHSession.describe(error), -1)
        }
    }

    // MARK: - 文本工具

    private func readableError(_ result: (out: String, err: String, exit: Int)) -> String {
        let combined = result.err.isEmpty ? result.out : result.err
        let line = firstMeaningfulLine(combined)
        return line.isEmpty ? "命令执行失败（exit \(result.exit)）" : line
    }

    private func firstMeaningfulLine(_ text: String) -> String {
        for line in text.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { return s }
        }
        return ""
    }

    private func looksLikeError(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("error ") || lower.contains("error:") ||
               lower.hasPrefix("error") || lower.contains("command not found") ||
               lower.contains("access denied") || lower.contains("permission denied")
    }

    private func cleanCell(_ value: String) -> String {
        // MySQL -B 把制表符/换行转义成 \t \n，还原成可读形式。
        value.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\\t", with: "  ")
            .replacingOccurrences(of: "\\n", with: " ")
    }

    private func escapeSQLIdentifier(_ name: String) -> String {
        name.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "\"", with: "")
    }

    private func jsString(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "'\(escaped)'"
    }

    private func uriEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func stringifyJSONValue(_ value: Any?) -> String {
        guard let value else { return "" }
        if value is NSNull { return "NULL" }
        if let str = value as? String { return str }
        if let num = value as? NSNumber { return num.stringValue }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
           let text = String(data: data, encoding: .utf8) { return text }
        return "\(value)"
    }
}

// MARK: - QueryResult 便捷构造

extension QueryResult {
    static var successEmpty: QueryResult {
        QueryResult(columns: ["结果"], rows: [], message: "查询完成，无数据", isWriteOperation: false)
    }
}
