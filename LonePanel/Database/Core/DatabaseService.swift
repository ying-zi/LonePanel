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
    /// 建连时记下的服务器代次；与 ServerSession.connectionEpoch 不符即判过期，强制重建。
    private var connectedEpoch: Int = -1

    @discardableResult
    func ensureConnected(force: Bool = false) async -> Bool {
        guard let info = ServerSession.shared.currentServer else {
            lastError = L10n.t("Please add and select a server in Settings → My Servers first")
            return false
        }
        let epoch = ServerSession.shared.connectionEpoch
        if !force, isConnected, connectedServerID == info.id, connectedEpoch == epoch, session != nil { return true }
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
            connectedEpoch = ServerSession.shared.connectionEpoch
            isConnected = true
            return true
        } catch {
            session?.close()
            session = nil
            connectedEpoch = -1
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
        connectedEpoch = -1
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
            // 探测容器内真实可用的客户端命令名：mariadb:11 只有 mariadb、没有 mysql；
            // mongosh/mongo 也因版本而异。停机的容器无法 exec，探测失败时回退到默认名。
            let client = await detectClientCommand(for: kind, containerID: cid)
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
                inlinePassword: password,
                containerClient: client
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
            // 管理容器内数据库必须用 root（1Panel 口径）：只有 root 有列全部库、建库、删库、
            // 管理用户的权限。应用用户（MYSQL_USER/MARIADB_USER）通常仅被授予单个库的权限，
            // 用它连接会「看不到已创建的库、也无法建删库」——这正是读不出库的根因。
            let rootPassword = env["MARIADB_ROOT_PASSWORD"] ?? env["MYSQL_ROOT_PASSWORD"] ?? ""
            let database = env["MARIADB_DATABASE"] ?? env["MYSQL_DATABASE"] ?? ""
            return ("root", rootPassword, database)
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

    /// 按类型探测容器内真实可执行的客户端名。命令名均为硬编码常量，无注入风险。
    /// 停机容器无法 exec，返回 nil 让调用方回退到类型默认客户端。
    private func detectClientCommand(for kind: DatabaseKind, containerID: String) async -> String? {
        let candidates: [String]
        switch kind {
        case .mysql: candidates = ["mysql", "mariadb"]
        case .postgresql: candidates = ["psql"]
        case .mongodb: candidates = ["mongosh", "mongo"]
        case .redis: candidates = ["redis-cli"]
        }
        let quoted = ShellQuote.quote(containerID)
        for candidate in candidates {
            let probe = await run(
                "docker exec \(quoted) sh -c 'command -v \(candidate) >/dev/null 2>&1'",
                timeout: 8
            )
            if probe.exit == 0 { return candidate }
        }
        return nil
    }

    private static func containerStatus(_ status: String) -> String {
        let s = status.lowercased()
        if s.contains("paused") { return L10n.t("Paused") }
        if s.hasPrefix("up") { return L10n.t("Running") }
        return L10n.t("Stopped")
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
            return .failed(connection.lastError ?? L10n.t("Connection Failed"))
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
        case .mysql:
            // 隐藏 MySQL/MariaDB 系统库，只展示用户可管理的业务库。
            let system: Set<String> = ["information_schema", "mysql", "performance_schema", "sys"]
            let items = parseLines(result.out).filter { !system.contains($0.name.lowercased()) }
            return .success(items)
        default:
            return .success(parseLines(result.out))
        }
    }

    /// 列出某个库下的表（MySQL/PostgreSQL）或集合（MongoDB）。
    func listTables(_ conn: DatabaseConnection, database: String) async -> Result<[DatabaseItem], DatabaseError> {
        let command: String
        switch conn.kind {
        case .mysql:
            // 用全限定名指定库，不依赖连接前缀的 -D：既避免初始库被删导致全挂，
            // 也保证浏览任意库时列的是所选库的表。
            let sql = "SHOW TABLES FROM `\(escapeSQLIdentifier(database))`"
            command = "\(mysqlBase(conn)) -N -B -e \(ShellQuote.quote(sql)) 2>&1"
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

    /// 读取表 / 集合 / Key 的结构，复用 QueryResult 表格渲染。
    /// - MySQL: DESCRIBE（Field/Type/Null/Key/Default/Extra）
    /// - PostgreSQL: information_schema.columns（列/类型/可空/默认值）
    /// - MongoDB: 采样首条文档推断字段名与类型
    /// - Redis: key 的 TYPE / TTL / ENCODING / MEMORY USAGE 元信息
    /// 所有外部输入经 escape / sqlString / jsString + ShellQuote，命令走带 epoch 校验的 run()。
    func fetchTableSchema(_ conn: DatabaseConnection, database: String, table: String) async -> Result<QueryResult, DatabaseError> {
        switch conn.kind {
        case .mysql:
            let sql = "DESCRIBE `\(escapeSQLIdentifier(database))`.`\(escapeSQLIdentifier(table))`"
            return await runTable("\(mysqlBase(conn)) -B -e \(ShellQuote.quote(sql)) 2>&1")

        case .postgresql:
            let sql = "SELECT column_name AS \"Column\", data_type AS \"Type\", is_nullable AS \"Nullable\", COALESCE(column_default, '') AS \"Default\" FROM information_schema.columns WHERE table_schema = 'public' AND table_name = \(sqlString(table)) ORDER BY ordinal_position"
            return await runTable("\(psqlBase(conn, database: database)) -c \(ShellQuote.quote(sql)) 2>&1")

        case .mongodb:
            let uri = mongoURI(conn, database: database)
            let js = "var d=db.getCollection(\(jsString(table))).find().limit(1).toArray()[0]; JSON.stringify(d?Object.keys(d).map(function(k){return {Field:k,Type:typeof d[k]}}):[])"
            return await runMongoJSON("\(mongoClient(conn)) \(ShellQuote.quote(uri)) --quiet --eval \(ShellQuote.quote(js)) 2>&1")

        case .redis:
            let q = ShellQuote.quote(table)
            let typeOut = await run("\(redisBase(conn)) TYPE \(q) 2>&1", timeout: listTimeout)
            guard typeOut.exit == 0 else {
                return .failure(.commandFailed(message: readableError(typeOut)))
            }
            let type = typeOut.out.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "key: ", with: "")
            func meta(_ command: String) async -> String {
                let r = await run("\(redisBase(conn)) \(command) \(q) 2>&1", timeout: listTimeout)
                let v = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
                return r.exit == 0 && !v.isEmpty ? v : "—"
            }
            let ttl = await meta("TTL")
            let enc = await meta("OBJECT ENCODING")
            let mem = await meta("MEMORY USAGE")
            return .success(QueryResult(
                columns: ["Property", "Value"],
                rows: [["Type", type], ["TTL (seconds)", ttl], ["Encoding", enc], ["Memory (bytes)", mem]],
                message: L10n.t("Key metadata"), isWriteOperation: false
            ))
        }
    }

    // MARK: - 执行自定义命令 / SQL

    /// 执行用户输入的 SQL（MySQL/PostgreSQL）或原始命令（MongoDB eval / Redis 命令）。
    func execute(_ conn: DatabaseConnection, database: String, statement: String) async -> Result<QueryResult, DatabaseError> {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.commandFailed(message: L10n.t("Enter a statement to execute"))) }

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
            // Redis 靠"空格=参数分隔"解析命令，不能整段 quote 成一个参数。
            // 逐 token quote：保留多参数语义，同时杜绝 shell 对 *、>、&、;、$ 的展开/注入。
            command = "\(redisBase(conn)) --no-raw \(quoteRedisArgs(trimmed)) 2>&1"
        }
        return await runTable(command)
    }

    /// 把用户输入的 Redis 原始命令按空白切成 token 并逐个 shell-quote。
    /// 例如 `KEYS *` → `'KEYS' '*'`（* 不再被 shell 当通配符展开）。
    private func quoteRedisArgs(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { ShellQuote.quote(String($0)) }
            .joined(separator: " ")
    }

    // MARK: - 库管理（新增 / 删除 / 重命名）

    /// 校验库名：仅字母、数字、下划线，长度 1…64，防止 SQL / shell 注入。
    private func validDatabaseName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }
        let allowed = trimmed.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) ||   // 0-9
            (scalar.value >= 65 && scalar.value <= 90) ||   // A-Z
            (scalar.value >= 97 && scalar.value <= 122) ||  // a-z
            scalar.value == 95                              // _
        }
        return allowed ? trimmed : nil
    }

    /// 新建数据库。MongoDB 库随首个集合隐式创建；Redis 使用固定 db 索引，不支持新建。
    func createDatabase(_ conn: DatabaseConnection, name rawName: String) async -> Result<String, DatabaseError> {
        guard let name = validDatabaseName(rawName) else {
            return .failure(.commandFailed(message: L10n.t("Database name may contain only letters, digits and underscores, up to 64 characters")))
        }
        let command: String
        switch conn.kind {
        case .mysql:
            let sql = "CREATE DATABASE IF NOT EXISTS `\(name)`"
            command = "\(mysqlBase(conn)) -e \(ShellQuote.quote(sql)) 2>&1"
        case .postgresql:
            let sql = "CREATE DATABASE \"\(name)\""
            command = "\(psqlBase(conn, database: "postgres")) -c \(ShellQuote.quote(sql)) 2>&1"
        case .mongodb:
            let uri = mongoURI(conn, database: "admin")
            let js = "db.getSiblingDB(\(jsString(name))).createCollection('_lonepanel_init'); 'ok'"
            command = "\(mongoClient(conn)) \(ShellQuote.quote(uri)) --quiet --eval \(ShellQuote.quote(js)) 2>&1"
        case .redis:
            return .failure(.commandFailed(message: L10n.t("Redis uses fixed DB indexes (0-15); databases cannot be created")))
        }
        return await runWrite(command, success: L10n.f("Database %@ created", name))
    }

    /// 一步到位：建库 + 创建专属用户 + 授权该用户访问该库（对齐 1Panel 的建库体验）。
    /// 建库成功但建用户失败时，明确告知库已创建、可到「用户管理」补建，避免出现"库建好了却没人能用"的黑洞。
    /// grantAll=true 时建管理员用户（授权全部库），否则仅授权刚创建的这个库（最小权限）。
    func createDatabaseWithUser(_ conn: DatabaseConnection,
                                database rawDatabase: String,
                                username rawUsername: String,
                                password rawPassword: String,
                                grantAll: Bool) async -> Result<String, DatabaseError> {
        guard let dbName = validDatabaseName(rawDatabase) else {
            return .failure(.commandFailed(message: L10n.t("Database name may contain only letters, digits and underscores, up to 64 characters")))
        }
        guard let user = validUserName(rawUsername) else {
            return .failure(.commandFailed(message: L10n.t("Username may contain only letters, digits, underscore, dot and hyphen, 1-64 characters")))
        }
        let pass = rawPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pass.isEmpty else {
            return .failure(.commandFailed(message: L10n.t("Password cannot be empty")))
        }

        // 1) 建库
        let dbResult = await createDatabase(conn, name: dbName)
        guard case .success = dbResult else { return dbResult }

        // 2) 建专属用户并授权。用户绑定在库上：非管理员只授权这一库。
        let userResult = await createUser(
            conn, username: user, password: pass,
            database: grantAll ? "" : dbName, isAdmin: grantAll
        )
        switch userResult {
        case .success:
            let scope = grantAll ? L10n.t("All databases (admin)") : L10n.f("Only %@", String(describing: (dbName)))
            return .success("Database \(dbName) created; dedicated user \(user) created and granted (\(scope))")
        case .failure(let error):
            return .failure(.commandFailed(
                message: L10n.f("Database %@ created, but dedicated user %@ creation failed: %@. Go to \"Instance Management > User Management\" to create and grant manually.", String(describing: (dbName)), String(describing: (user)), String(describing: (error.localizedDescription)))
            ))
        }
    }

    /// 删除数据库。Redis 不支持删除 db 索引（可进入该库用 FLUSHDB 清空数据）。
    func dropDatabase(_ conn: DatabaseConnection, name rawName: String) async -> Result<String, DatabaseError> {
        guard let name = validDatabaseName(rawName) else {
            return .failure(.commandFailed(message: L10n.t("Invalid database name")))
        }
        let command: String
        switch conn.kind {
        case .mysql:
            let sql = "DROP DATABASE IF EXISTS `\(name)`"
            command = "\(mysqlBase(conn)) -e \(ShellQuote.quote(sql)) 2>&1"
        case .postgresql:
            let sql = "DROP DATABASE IF EXISTS \"\(name)\""
            command = "\(psqlBase(conn, database: "postgres")) -c \(ShellQuote.quote(sql)) 2>&1"
        case .mongodb:
            let uri = mongoURI(conn, database: "admin")
            let js = "db.getSiblingDB(\(jsString(name))).dropDatabase(); 'ok'"
            command = "\(mongoClient(conn)) \(ShellQuote.quote(uri)) --quiet --eval \(ShellQuote.quote(js)) 2>&1"
        case .redis:
            return .failure(.commandFailed(message: L10n.t("Redis does not support deleting a DB index; open it to clear data")))
        }
        return await runWrite(command, success: L10n.f("Database %@ deleted", name))
    }

    /// 重命名数据库。PostgreSQL 用 ALTER；MySQL 建新库+逐表迁移+删旧库；MongoDB 逐集合迁移；Redis 不支持。
    func renameDatabase(_ conn: DatabaseConnection, from rawOld: String, to rawNew: String) async -> Result<String, DatabaseError> {
        guard let old = validDatabaseName(rawOld), let new = validDatabaseName(rawNew) else {
            return .failure(.commandFailed(message: L10n.t("Database name may contain only letters, digits and underscores")))
        }
        guard old != new else {
            return .failure(.commandFailed(message: L10n.t("Old and new names are the same; nothing to change")))
        }
        switch conn.kind {
        case .postgresql:
            let sql = "ALTER DATABASE \"\(old)\" RENAME TO \"\(new)\""
            let command = "\(psqlBase(conn, database: "postgres")) -c \(ShellQuote.quote(sql)) 2>&1"
            return await runWrite(command, success: L10n.f("Renamed to %@", new))
        case .mysql:
            return await mysqlRenameDatabase(conn, from: old, to: new)
        case .mongodb:
            return await mongoRenameDatabase(conn, from: old, to: new)
        case .redis:
            return .failure(.commandFailed(message: L10n.t("Redis does not support renaming databases")))
        }
    }

    /// MySQL 无原生 RENAME DATABASE：建目标库 → 逐表 RENAME TABLE → 删源库。
    private func mysqlRenameDatabase(_ conn: DatabaseConnection, from old: String, to new: String) async -> Result<String, DatabaseError> {
        let createSQL = "CREATE DATABASE IF NOT EXISTS `\(new)`"
        let created = await run("\(mysqlBase(conn)) -e \(ShellQuote.quote(createSQL)) 2>&1", timeout: listTimeout)
        guard created.exit == 0, !looksLikeError(created.out) else {
            return .failure(.commandFailed(message: readableError(created)))
        }
        let showSQL = "SHOW TABLES FROM `\(old)`"
        let listed = await run("\(mysqlBase(conn)) -N -B -e \(ShellQuote.quote(showSQL)) 2>&1", timeout: listTimeout)
        guard listed.exit == 0 else {
            return .failure(.commandFailed(message: readableError(listed)))
        }
        let tables = parseLines(listed.out).map(\.name)
        for table in tables {
            let sql = "RENAME TABLE `\(old)`.`\(table)` TO `\(new)`.`\(table)`"
            let moved = await run("\(mysqlBase(conn)) -e \(ShellQuote.quote(sql)) 2>&1", timeout: listTimeout)
            guard moved.exit == 0, !looksLikeError(moved.out) else {
                return .failure(.commandFailed(message: L10n.f("Failed to migrate table %@: %@", String(describing: (table)), String(describing: (readableError(moved))))))
            }
        }
        let dropSQL = "DROP DATABASE IF EXISTS `\(old)`"
        let dropped = await run("\(mysqlBase(conn)) -e \(ShellQuote.quote(dropSQL)) 2>&1", timeout: listTimeout)
        guard dropped.exit == 0 else {
            return .failure(.commandFailed(message: readableError(dropped)))
        }
        return .success("Renamed \(old) to \(new), migrated \(tables.count) tables")
    }

    /// MongoDB 无原生 renameDB：用 adminCommand 逐集合 renameCollection 到目标库。
    private func mongoRenameDatabase(_ conn: DatabaseConnection, from old: String, to new: String) async -> Result<String, DatabaseError> {
        let uri = mongoURI(conn, database: "admin")
        // 注意：c 是 JS 回调变量，必须在 JS 侧拼接，不能放进 Swift 的 \(...) 插值。
        let js = "db.getSiblingDB(\(jsString(old))).getCollectionNames().forEach(function(c){" +
                 "db.adminCommand({renameCollection: \(jsString(old)) + '.' + c, to: \(jsString(new)) + '.' + c})}); 'ok'"
        let command = "\(mongoClient(conn)) \(ShellQuote.quote(uri)) --quiet --eval \(ShellQuote.quote(js)) 2>&1"
        return await runWrite(command, success: L10n.f("Renamed %@ to %@", old, new))
    }

    /// 写类命令的统一执行：exit=0 且输出无错误特征即视为成功。
    private func runWrite(_ command: String, success: String) async -> Result<String, DatabaseError> {
        let result = await run(command, timeout: queryTimeout)
        guard result.exit == 0 else {
            return .failure(.commandFailed(message: readableError(result)))
        }
        let out = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if looksLikeError(out) {
            return .failure(.commandFailed(message: firstMeaningfulLine(out)))
        }
        return .success(success)
    }

    // MARK: - 实例管理（改密 / 用户管理）

    /// 管理员名：各类型默认管理员账号。
    private func adminUser(_ conn: DatabaseConnection) -> String {
        if !conn.username.isEmpty { return conn.username }
        switch conn.kind {
        case .mysql, .postgresql: return "root"
        case .mongodb: return "root"
        case .redis: return "default"
        }
    }

    /// 重置管理员口令。成功后同步写回凭据覆盖层，保证本次会话与下次发现都使用新口令。
    /// - mysql/mariadb：`ALTER USER` 改 root@localhost 与 root@% 两个常见 host；旧版本回退 SET PASSWORD。
    /// - postgresql：`ALTER USER ... PASSWORD`。
    /// - mongodb：admin 库 `changeUserPassword`。
    /// - redis：`CONFIG SET requirepass`（同时 CONFIG REWRITE 尝试持久化）。
    func resetAdminPassword(_ conn: DatabaseConnection, newPassword: String) async -> Result<String, DatabaseError> {
        let trimmed = newPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.commandFailed(message: L10n.t("Password cannot be empty")))
        }

        switch conn.kind {
        case .mysql:
            let user = sqlString(adminUser(conn))
            let pass = sqlString(trimmed)
            // 逐个 host 尝试，任一成功即可：某个 host 的账号不存在不应拖垮整体。
            var anySuccess = false
            var lastError = ""
            for host in ["localhost", "%"] {
                let sql = "ALTER USER \(user)@'\(host)' IDENTIFIED BY \(pass); FLUSH PRIVILEGES"
                let r = await run("\(mysqlBase(conn)) -e \(ShellQuote.quote(sql)) 2>&1", timeout: queryTimeout)
                if r.exit == 0 && !looksLikeError(r.out) { anySuccess = true; break }
                lastError = firstMeaningfulLine(r.out)
            }
            if anySuccess { return commitPassword(conn, trimmed, message: L10n.t("Admin password updated")) }
            // 老版本 MySQL/MariaDB 无 ALTER USER 时回退 SET PASSWORD（当前 host）。
            let fallbackSQL = "SET PASSWORD FOR \(user) = PASSWORD(\(pass)); FLUSH PRIVILEGES"
            let fallback = await run("\(mysqlBase(conn)) -e \(ShellQuote.quote(fallbackSQL)) 2>&1", timeout: queryTimeout)
            guard fallback.exit == 0, !looksLikeError(fallback.out) else {
                return .failure(.commandFailed(message: lastError.isEmpty ? firstMeaningfulLine(fallback.out) : lastError))
            }
            return commitPassword(conn, trimmed, message: L10n.t("Admin password updated (compatibility mode)"))

        case .postgresql:
            let sql = "ALTER USER \(sqlIdentifier(adminUser(conn))) WITH PASSWORD \(sqlString(trimmed))"
            let cmd = "\(psqlBase(conn, database: "postgres")) -c \(ShellQuote.quote(sql)) 2>&1"
            let result = await run(cmd, timeout: queryTimeout)
            guard result.exit == 0, !looksLikeError(result.out) else {
                return .failure(.commandFailed(message: firstMeaningfulLine(result.out)))
            }
            return commitPassword(conn, trimmed, message: L10n.t("Admin password updated"))

        case .mongodb:
            let uri = mongoURI(conn, database: "admin")
            let js = "db.changeUserPassword(\(jsString(adminUser(conn))), \(jsString(trimmed))); 'ok'"
            let cmd = "\(mongoClient(conn)) \(ShellQuote.quote(uri)) --quiet --eval \(ShellQuote.quote(js)) 2>&1"
            let result = await run(cmd, timeout: queryTimeout)
            guard result.exit == 0, !looksLikeError(result.out) else {
                return .failure(.commandFailed(message: firstMeaningfulLine(result.out)))
            }
            return commitPassword(conn, trimmed, message: L10n.t("Admin password updated"))

        case .redis:
            let base = redisBase(conn, overridePassword: true)
            let set = await run("\(base) CONFIG SET requirepass \(ShellQuote.quote(trimmed)) 2>&1", timeout: queryTimeout)
            // redis-cli 的 CONFIG SET 成功时返回英文 "OK"（协议固定，非本地化文案）。
            // 旧代码用 L10n.t("OK") 判断，中文包下变成「确定」，导致永远判失败——改为固定英文。
            guard set.exit == 0, set.out.uppercased().contains("OK"), !looksLikeError(set.out) else {
                return .failure(.commandFailed(message: firstMeaningfulLine(set.out)))
            }
            _ = await run("\(base) CONFIG REWRITE 2>&1", timeout: queryTimeout)
            return commitPassword(conn, trimmed, message: L10n.t("requirepass updated"))
        }
    }

    // MARK: - Redis 配置与持久化

    /// 读取 Redis 配置与状态：CONFIG GET 关键项 + INFO。
    /// 安全：CONFIG GET 用固定白名单逐项读取，绝不含 requirepass/masterauth 明文；
    /// requirepass 只探测是否设置（非空即视为已设置），不返回其值。
    func fetchRedisConfig(_ conn: DatabaseConnection) async -> Result<RedisConfigSnapshot, DatabaseError> {
        guard conn.kind == .redis else {
            return .failure(.commandFailed(message: L10n.t("Only Redis supports configuration management")))
        }
        let base = redisBase(conn)

        // 配置白名单：key 是 redis 配置项名，展示名走本地化。
        let keys: [(config: String, label: String)] = [
            ("maxmemory", "Max memory"),
            ("maxmemory-policy", "Eviction policy"),
            ("appendonly", "AOF enabled"),
            ("appendfsync", "AOF fsync"),
            ("save", "RDB rules"),
            ("dbfilename", "RDB file"),
            ("dir", "Data directory"),
            ("maxclients", "Max clients"),
            ("timeout", "Client timeout"),
        ]
        var configMap: [String: String] = [:]
        for item in keys {
            let res = await run("\(base) CONFIG GET \(ShellQuote.quote(item.config)) 2>&1", timeout: listTimeout)
            if res.exit == 0, let value = parseRedisConfigGet(res.out, key: item.config) {
                configMap[item.config] = value
            }
        }

        var snapshot = RedisConfigSnapshot()
        snapshot.items = keys.compactMap { item in
            guard let value = configMap[item.config] else { return nil }
            return RedisConfigItem(id: item.config, key: L10n.t(item.label), value: value)
        }

        // 是否设置密码：只读回「(empty)」与否，不保留明文。
        let passRes = await run("\(base) CONFIG GET requirepass 2>&1", timeout: listTimeout)
        if let passValue = parseRedisConfigGet(passRes.out, key: "requirepass") {
            snapshot.passwordSet = !passValue.isEmpty && passValue != "(empty)"
        }

        // INFO 状态。
        let infoRes = await run("\(base) INFO ALL 2>&1", timeout: listTimeout)
        if infoRes.exit == 0 {
            snapshot.info = parseRedisInfo(infoRes.out)
        }

        // 推断持久化模式：appendonly yes → aof；否则看 save 是否为空。
        if configMap["appendonly"]?.lowercased() == "yes" {
            snapshot.mode = .aof
        } else if let save = configMap["save"], !save.isEmpty, save != "(empty)" {
            snapshot.mode = .rdb
        } else {
            snapshot.mode = .none
        }
        return .success(snapshot)
    }

    /// 切换 Redis 持久化模式。RDB/AOF 的开关键均用固定字面量，不接受外部输入。
    func setRedisPersistence(_ conn: DatabaseConnection, mode: RedisPersistenceMode) async -> Result<String, DatabaseError> {
        guard conn.kind == .redis else {
            return .failure(.commandFailed(message: L10n.t("Only Redis supports configuration management")))
        }
        let base = redisBase(conn)

        // 依次下发的命令；每条都必须返回 OK。
        var commands: [String]
        switch mode {
        case .aof:
            commands = ["CONFIG SET appendonly yes"]
        case .rdb:
            commands = ["CONFIG SET appendonly no", "CONFIG SET save \"3600 1 300 100 60 10000\""]
        case .none:
            commands = ["CONFIG SET appendonly no", "CONFIG SET save \"\""]
        }

        for command in commands {
            let res = await run("\(base) \(command) 2>&1", timeout: queryTimeout)
            guard res.exit == 0, res.out.uppercased().contains("OK"), !looksLikeError(res.out) else {
                return .failure(.commandFailed(message: firstMeaningfulLine(res.out)))
            }
        }
        // 尽力持久化配置本身；CONFIG REWRITE 在某些只读/受限实例会失败，不影响本次切换结果。
        _ = await run("\(base) CONFIG REWRITE 2>&1", timeout: queryTimeout)
        return .success(L10n.f("Switched to %@", mode.title))
    }

    /// 手动触发持久化保存。BGSAVE / BGREWRITEAOF 为异步，返回任务是否成功启动。
    enum RedisSaveAction: String {
        case bgSave = "BGSAVE"
        case bgRewriteAOF = "BGREWRITEAOF"
    }

    func runRedisSave(_ conn: DatabaseConnection, action: RedisSaveAction) async -> Result<String, DatabaseError> {
        guard conn.kind == .redis else {
            return .failure(.commandFailed(message: L10n.t("Only Redis supports configuration management")))
        }
        let base = redisBase(conn)
        let res = await run("\(base) \(action.rawValue) 2>&1", timeout: queryTimeout)
        let out = res.out.isEmpty ? res.err : res.out
        guard res.exit == 0, !looksLikeError(out) else {
            return .failure(.commandFailed(message: firstMeaningfulLine(out)))
        }
        return .success(firstMeaningfulLine(out).isEmpty ? L10n.t("Save started") : firstMeaningfulLine(out))
    }

    /// 解析 CONFIG GET 的单项值：输出为两行一组（key 行 + value 行）。
    private func parseRedisConfigGet(_ text: String, key: String) -> String? {
        let lines = text.split(separator: "\n").map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard let idx = lines.firstIndex(where: { $0.lowercased() == key.lowercased() }),
              idx + 1 < lines.count else { return nil }
        return lines[idx + 1]
    }

    /// 解析 INFO ALL：跳过 # 注释与空行，按 key:value 提取。
    private func parseRedisInfo(_ text: String) -> RedisServerInfo {
        var map: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let s = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty || s.hasPrefix("#") { continue }
            guard let colon = s.firstIndex(of: ":") else { continue }
            let k = String(s[..<colon])
            let v = String(s[s.index(after: colon)...])
            map[k] = v
        }
        var info = RedisServerInfo()
        info.version = map["redis_version"] ?? "—"
        info.mode = map["redis_mode"] ?? "—"
        info.connectedClients = map["connected_clients"] ?? "—"
        info.usedMemory = map["used_memory_human"] ?? "—"
        info.uptimeDays = map["uptime_in_days"] ?? "—"

        // 持久化状态摘要：AOF 是否开启 + 最近一次 RDB 保存。
        let aof = (map["aof_enabled"] == "1") ? L10n.t("AOF on") : L10n.t("AOF off")
        if let lastSave = map["rdb_last_save_time"], let ts = Double(lastSave), ts > 0 {
            let d = Date(timeIntervalSince1970: ts)
            info.persistence = "\(aof) · \(L10n.t("Last RDB save")): \(L10n.dateTimeText(d))"
        } else {
            info.persistence = aof
        }

        // key 总数：累加 keyspace 段里各 db 的 keys 数。
        var total = 0
        for (k, v) in map where k.hasPrefix("db") && k.dropFirst().allSatisfy({ $0.isNumber }) {
            let keys = v.split(separator: ",").first?.split(separator: "=").last.map(String.init) ?? "0"
            total += Int(keys) ?? 0
        }
        info.totalKeys = "\(total)"
        return info
    }

    /// 列出用户。detail 放角色 / host 等附加信息。
    func listUsers(_ conn: DatabaseConnection) async -> Result<[DatabaseItem], DatabaseError> {
        let result: (out: String, err: String, exit: Int)
        switch conn.kind {
        case .mysql:
            let sql = "SELECT CONCAT(User,'@',Host), CASE WHEN Super_priv='Y' THEN '管理员' ELSE '普通用户' END FROM mysql.user WHERE User NOT IN ('','mysql.infoschema','mysql.session','mysql.sys') ORDER BY User,Host"
            result = await run("\(mysqlBase(conn)) -N -B -e \(ShellQuote.quote(sql)) 2>&1", timeout: listTimeout)
        case .postgresql:
            let sql = "SELECT rolname, CASE WHEN rolsuper THEN '管理员' ELSE '普通用户' END FROM pg_roles WHERE rolcanlogin ORDER BY rolname"
            result = await run("\(psqlBase(conn, database: "postgres")) -t -A -F '|' -c \(ShellQuote.quote(sql)) 2>&1", timeout: listTimeout)
        case .mongodb:
            let uri = mongoURI(conn, database: "admin")
            let js = "db.getSiblingDB('admin').getUsers().users.map(function(u){return u.user+'|'+u.roles.map(function(r){return r.role+'@'+r.db}).join(',')}).join('\\n')"
            result = await run("\(mongoClient(conn)) \(ShellQuote.quote(uri)) --quiet --eval \(ShellQuote.quote(js)) 2>&1", timeout: listTimeout)
        case .redis:
            // Redis 6+ ACL 用户；用 -F 无关，`ACL LIST` 逐行输出。
            result = await run("\(redisBase(conn)) ACL LIST 2>&1", timeout: listTimeout)
        }
        guard result.exit == 0 else {
            return .failure(.commandFailed(message: readableError(result)))
        }
        return .success(parseUserLines(result.out, kind: conn.kind))
    }

    /// 新建用户并按需授权。MongoDB / Redis 的权限模型不同，单独处理。
    func createUser(_ conn: DatabaseConnection, username: String, password: String,
                    database: String, isAdmin: Bool) async -> Result<String, DatabaseError> {
        guard let user = validUserName(username) else {
            return .failure(.commandFailed(message: L10n.t("Username may contain only letters, digits, underscore, dot and hyphen, 1-64 characters")))
        }
        let pass = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pass.isEmpty else { return .failure(.commandFailed(message: L10n.t("Password cannot be empty"))) }

        let command: String
        switch conn.kind {
        case .mysql:
            let u = sqlString(user), p = sqlString(pass)
            var sql = "CREATE USER \(u)@'%' IDENTIFIED BY \(p)"
            if database.isEmpty || isAdmin {
                sql += "; GRANT ALL PRIVILEGES ON *.* TO \(u)@'%' WITH GRANT OPTION"
            } else {
                sql += "; GRANT ALL PRIVILEGES ON `\(escapeSQLIdentifier(database))`.* TO \(u)@'%'"
            }
            sql += "; FLUSH PRIVILEGES"
            command = "\(mysqlBase(conn)) -e \(ShellQuote.quote(sql)) 2>&1"
        case .postgresql:
            let u = sqlIdentifier(user), p = sqlString(pass)
            var sql = isAdmin
                ? "CREATE USER \(u) WITH PASSWORD \(p) SUPERUSER"
                : "CREATE USER \(u) WITH PASSWORD \(p)"
            if !database.isEmpty && !isAdmin {
                sql += "; GRANT ALL PRIVILEGES ON DATABASE \(sqlIdentifier(database)) TO \(u)"
            }
            command = "\(psqlBase(conn, database: "postgres")) -c \(ShellQuote.quote(sql)) 2>&1"
        case .mongodb:
            let uri = mongoURI(conn, database: "admin")
            let dbName = database.isEmpty ? "admin" : database
            let role = isAdmin ? "'root', db:'admin'" : "'readWrite', db:\(jsString(dbName))"
            let js = "db.getSiblingDB('admin').createUser({user:\(jsString(user)),pwd:\(jsString(pass)),roles:[{role:\(role)}]}); 'ok'"
            command = "\(mongoClient(conn)) \(ShellQuote.quote(uri)) --quiet --eval \(ShellQuote.quote(js)) 2>&1"
        case .redis:
            // Redis 6 ACL：启用用户、设置密码、授予全部 key 与命令。
            // 关键：口令前缀 `>`、key 模式 `~*`、channel 模式 `&*`、类别 `+@all`
            // 必须逐个整体 quote。否则 `>` 被 shell 当输出重定向、`&` 当后台执行符、
            // `*` 当通配符展开——ACL 会解析出错，口令甚至被写进一个以口令命名的文件。
            let base = redisBase(conn, overridePassword: true)
            let passwordToken = ShellQuote.quote(">" + pass)
            let keyPattern = ShellQuote.quote("~*")
            let channelPattern = ShellQuote.quote("&*")
            let category = ShellQuote.quote("+@all")
            command = "\(base) ACL SETUSER \(ShellQuote.quote(user)) on \(passwordToken) \(keyPattern) \(channelPattern) \(category) 2>&1"
        }
        return await runWrite(command, success: L10n.f("User %@ created", user))
    }

    /// 删除用户。MySQL 需同时删除常见 host。
    func deleteUser(_ conn: DatabaseConnection, rawName: String) async -> Result<String, DatabaseError> {
        let user = rawName.split(separator: "@").first.map(String.init) ?? rawName
        guard let safe = validUserName(user) else {
            return .failure(.commandFailed(message: L10n.t("Invalid username")))
        }
        let command: String
        switch conn.kind {
        case .mysql:
            let u = sqlString(safe)
            let sql = "DROP USER IF EXISTS \(u)@'localhost'; DROP USER IF EXISTS \(u)@'%'; FLUSH PRIVILEGES"
            command = "\(mysqlBase(conn)) -e \(ShellQuote.quote(sql)) 2>&1"
        case .postgresql:
            command = "\(psqlBase(conn, database: "postgres")) -c \(ShellQuote.quote("DROP USER IF EXISTS \(sqlIdentifier(safe))")) 2>&1"
        case .mongodb:
            let uri = mongoURI(conn, database: "admin")
            let js = "db.getSiblingDB('admin').dropUser(\(jsString(safe))); 'ok'"
            command = "\(mongoClient(conn)) \(ShellQuote.quote(uri)) --quiet --eval \(ShellQuote.quote(js)) 2>&1"
        case .redis:
            let base = redisBase(conn, overridePassword: true)
            command = "\(base) ACL DELUSER \(ShellQuote.quote(safe)) 2>&1"
        }
        return await runWrite(command, success: L10n.f("User %@ deleted", safe))
    }

    /// 修改某个用户的密码。
    func changeUserPassword(_ conn: DatabaseConnection, rawName: String, newPassword: String) async -> Result<String, DatabaseError> {
        let user = rawName.split(separator: "@").first.map(String.init) ?? rawName
        guard let safe = validUserName(user) else {
            return .failure(.commandFailed(message: L10n.t("Invalid username")))
        }
        let pass = newPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pass.isEmpty else { return .failure(.commandFailed(message: L10n.t("Password cannot be empty"))) }
        let command: String
        switch conn.kind {
        case .mysql:
            let u = sqlString(safe), p = sqlString(pass)
            let sql = "ALTER USER \(u)@'localhost' IDENTIFIED BY \(p); ALTER USER \(u)@'%' IDENTIFIED BY \(p); FLUSH PRIVILEGES"
            command = "\(mysqlBase(conn)) -e \(ShellQuote.quote(sql)) 2>&1"
        case .postgresql:
            let sql = "ALTER USER \(sqlIdentifier(safe)) WITH PASSWORD \(sqlString(pass))"
            command = "\(psqlBase(conn, database: "postgres")) -c \(ShellQuote.quote(sql)) 2>&1"
        case .mongodb:
            let uri = mongoURI(conn, database: "admin")
            let js = "db.getSiblingDB('admin').changeUserPassword(\(jsString(safe)), \(jsString(pass))); 'ok'"
            command = "\(mongoClient(conn)) \(ShellQuote.quote(uri)) --quiet --eval \(ShellQuote.quote(js)) 2>&1"
        case .redis:
            let base = redisBase(conn, overridePassword: true)
            // 口令前缀 `>` 必须和口令一起整体 quote，否则被 shell 当输出重定向。
            command = "\(base) ACL SETUSER \(ShellQuote.quote(safe)) \(ShellQuote.quote(">" + pass)) 2>&1"
        }
        return await runWrite(command, success: L10n.f("User %@ password updated", safe))
    }

    /// 改密成功后写入凭据覆盖层。远程连接的口令仍存钥匙串（原 credentialKey）。
    private func commitPassword(_ conn: DatabaseConnection, _ password: String, message: String) -> Result<String, DatabaseError> {
        if let cid = conn.containerID {
            ContainerCredentialStore.shared.set(password, for: cid)
        } else {
            do { try KeychainStore.save(password, for: conn.credentialKey) }
            catch { return .failure(.commandFailed(message: L10n.f("Password changed, but failed to save to Keychain: %@", String(describing: (error.localizedDescription))))) }
        }
        return .success(message)
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
        let columns = type == "hash" || type == "zset" ? ["Field", "Value"] : ["Value"]
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
                                    message: L10n.f("Type: %@", String(describing: (type))), isWriteOperation: false))
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
            return .success(L10n.t("Connected"))
        }
        return .failure(.commandFailed(message: readableError(result)))
    }

    // MARK: - 命令构造：各客户端

    /// MySQL 连接前缀。`-D` 只在调用方显式传入库时附加：
    /// 管理类命令（列库/建库/删库/改密/用户管理）不能绑定某个库，否则该初始库被删后所有命令都报
    /// `Unknown database` 全挂；需要库上下文时使用全限定名或显式传入 database。
    private func mysqlBase(_ conn: DatabaseConnection, database: String? = nil) -> String {
        let password = store.password(for: conn)
        var cmd: String
        // 容器内实例：docker exec 注入口令，容器内部本地连接，无需端口映射。
        if let cid = conn.containerID {
            var exec = "docker exec"
            if !password.isEmpty { exec += " -e MYSQL_PWD=\(ShellQuote.quote(password))" }
            let client = conn.containerClient ?? "mysql"
            cmd = "\(exec) \(ShellQuote.quote(cid)) \(client) -u \(ShellQuote.quote(conn.username))"
        } else {
            var parts: [String] = []
            if !password.isEmpty { parts.append("MYSQL_PWD=\(ShellQuote.quote(password))") }
            let prefix = parts.joined(separator: " ")
            cmd = (prefix.isEmpty ? "" : prefix + " ")
                + "mysql -h \(ShellQuote.quote(conn.host)) -P \(conn.port) -u \(ShellQuote.quote(conn.username))"
        }
        if let database, !database.isEmpty { cmd += " -D \(ShellQuote.quote(database))" }
        return cmd
    }

    private func psqlBase(_ conn: DatabaseConnection, database: String) -> String {
        let password = store.password(for: conn)
        if let cid = conn.containerID {
            var exec = "docker exec"
            if !password.isEmpty { exec += " -e PGPASSWORD=\(ShellQuote.quote(password))" }
            let client = conn.containerClient ?? "psql"
            return "\(exec) \(ShellQuote.quote(cid)) \(client) -U \(ShellQuote.quote(conn.username)) -d \(ShellQuote.quote(database))"
        }
        var parts: [String] = []
        if !password.isEmpty { parts.append("PGPASSWORD=\(ShellQuote.quote(password))") }
        var cmd = parts.joined(separator: " ")
        cmd += (cmd.isEmpty ? "" : " ") + "psql -h \(ShellQuote.quote(conn.host)) -p \(conn.port) -U \(ShellQuote.quote(conn.username)) -d \(ShellQuote.quote(database))"
        return cmd
    }

    /// - overridePassword: 改密操作中用刚设置的新密码连接（此时环境变量/钥匙串可能仍是旧值）。
    private func redisBase(_ conn: DatabaseConnection, overridePassword: Bool = false) -> String {
        var password = store.password(for: conn)
        if overridePassword, let cid = conn.containerID {
            // 容器实例：改密时优先取覆盖层最新值。
            password = ContainerCredentialStore.shared.password(for: cid, fallback: password)
        }
        if let cid = conn.containerID {
            var exec = "docker exec"
            if !password.isEmpty { exec += " -e REDISCLI_AUTH=\(ShellQuote.quote(password))" }
            let client = conn.containerClient ?? "redis-cli"
            var cmd = "\(exec) \(ShellQuote.quote(cid)) \(client)"
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
        // 容器内实例：在容器里跑探测到的客户端（mongosh/mongo），连接参数由 mongoURI 提供。
        if let cid = conn.containerID {
            let client = conn.containerClient ?? "mongosh"
            return "docker exec \(ShellQuote.quote(cid)) \(client)"
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
                                    message: L10n.f("%@ documents", String(describing: (array.count))), isWriteOperation: false))
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
                                        message: L10n.f("%@ results", String(describing: (array.count))), isWriteOperation: false))
        }
        return .success(QueryResult(columns: ["Result"], rows: [[out]],
                                    message: L10n.t("Command executed"), isWriteOperation: false))
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
            columns = ["Result"]
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
        return line.isEmpty ? "Command failed (exit \(result.exit))" : line
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

    /// 用户名校验：字母、数字、下划线、点、中划线，1–64。防止注入与 shell 特殊字符。
    private func validUserName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 64 else { return nil }
        let allowed = name.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) ||   // 0-9
            (scalar.value >= 65 && scalar.value <= 90) ||   // A-Z
            (scalar.value >= 97 && scalar.value <= 122) ||  // a-z
            scalar.value == 95 || scalar.value == 46 || scalar.value == 45 // _ . -
        }
        return allowed ? name : nil
    }

    /// SQL 字符串字面量：单引号加倍转义（标准 SQL），外层交给 ShellQuote。
    private func sqlString(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// SQL 标识符（PostgreSQL 双引号）：内部双引号加倍。
    private func sqlIdentifier(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// 解析用户列表输出：MySQL `name@host|角色`、PostgreSQL `name|角色`、
    /// MongoDB `name|role@db,...`、Redis `user name on ...`。
    private func parseUserLines(_ text: String, kind: DatabaseKind) -> [DatabaseItem] {
        text.split(separator: "\n").compactMap { line in
            let s = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { return nil }
            if kind == .redis {
                // `user default on ...` → name=default, detail=on ...
                let parts = s.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count >= 2, parts[0].lowercased() == "user" else { return nil }
                return DatabaseItem(name: parts[1], detail: parts.count > 2 ? parts[2] : nil)
            }
            let parts = s.split(separator: "|", maxSplits: 1).map(String.init)
            return DatabaseItem(name: parts[0], detail: parts.count > 1 ? parts[1] : nil)
        }
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
        QueryResult(columns: ["Result"], rows: [], message: L10n.t("Query complete, no data"), isWriteOperation: false)
    }
}
