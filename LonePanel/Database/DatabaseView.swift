import SwiftUI

/// 数据库模块主视图：顶部分段切换 连接 / 数据。
/// 连接页管理数据库客户端连接配置（密码存钥匙串）；数据页做 库→表→数据 浏览 + 自定义查询。
/// 数据库客户端运行在 SSH 服务器上，App 只下发命令与解析输出（服务端零依赖）。
struct DatabaseView: View {
    enum Section: String, CaseIterable {
        case connections = "连接"
        case browser = "数据"
    }

    @State private var section: Section = .connections
    @StateObject private var store = DatabaseConnectionStore.shared
    @ObservedObject private var dbConnection = DatabaseSSHConnection.shared

    var body: some View {
        NavigationStack {
            Group {
                switch section {
                case .connections:
                    ConnectionListView(store: store)
                case .browser:
                    DatabaseBrowserView(store: store)
                }
            }
            .navigationTitle("数据库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("模块", selection: $section) {
                        ForEach(Section.allCases, id: \.self) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SettingsGearButton()
                }
            }
        }
    }
}

// MARK: - 连接列表页

struct ConnectionListView: View {
    @ObservedObject var store: DatabaseConnectionStore
    @State private var editing: DatabaseConnection?
    @State private var showEditor = false

    var body: some View {
        List {
            if store.connections.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "cylinder.split.1x2")
                            .font(.system(size: 44))
                            .foregroundStyle(.tint)
                        Text("还没有数据库连接")
                            .font(.headline)
                        Text("添加一条连接，即可在 App 里浏览库表、查询数据、执行 SQL。\n数据库客户端需已安装在服务器上。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("添加连接") { showEditor = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            } else {
                Section {
                    ForEach(store.connections) { conn in
                        NavigationLink {
                            ConnectionDetailView(conn: conn, store: store)
                        } label: {
                            ConnectionRow(conn: conn)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                withAnimation { store.delete(conn) }
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button {
                                editing = conn
                                showEditor = true
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            .tint(.indigo)
                        }
                    }
                } header: {
                    Text("数据库连接")
                } footer: {
                    Text("连接配置保存在本机，密码存系统钥匙串。所有命令通过当前 SSH 服务器执行。")
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editing = nil
                    showEditor = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("添加连接")
            }
        }
        .sheet(isPresented: $showEditor) {
            ConnectionEditorView(conn: editing, store: store)
        }
    }
}

/// 连接列表行。
private struct ConnectionRow: View {
    let conn: DatabaseConnection

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: conn.kind.symbolName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(DatabaseView.kindColor(conn.kind))
                .frame(width: 34, height: 34)
                .background(DatabaseView.kindColor(conn.kind).opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(conn.name)
                    .font(.body.weight(.semibold))
                Text("\(conn.kind.title) · \(conn.endpoint)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 连接详情页（探测 + 测试 + 入口）

struct ConnectionDetailView: View {
    let conn: DatabaseConnection
    @ObservedObject var store: DatabaseConnectionStore

    @State private var availability: DatabaseAvailability?
    @State private var isChecking = false
    @State private var testResult: Result<String, DatabaseError>?
    @State private var isTesting = false

    var body: some View {
        List {
            Section("连接信息") {
                LabeledContent("名称", value: conn.name)
                LabeledContent("类型", value: conn.kind.title)
                LabeledContent("主机", value: conn.endpoint)
                LabeledContent("用户名", value: conn.username.isEmpty ? "（无）" : conn.username)
                LabeledContent("默认库", value: conn.database.isEmpty ? "（无）" : conn.database)
            }

            Section("客户端") {
                HStack(alignment: .top, spacing: 10) {
                    if isChecking {
                        ProgressView()
                        Text("正在探测 \(conn.kind.clientCommand) ...")
                            .foregroundStyle(.secondary)
                    } else if let availability {
                        switch availability {
                        case .available(let version):
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("客户端可用").foregroundStyle(.green)
                                Text(version).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        case .clientMissing:
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("未找到客户端").foregroundStyle(.orange)
                                Text("服务器上未安装 \(conn.kind.clientCommand)。请先在服务器安装对应客户端。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        case .failed(let message):
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("探测失败").foregroundStyle(.red)
                                Text(message).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("尚未探测").foregroundStyle(.secondary)
                    }
                }
                Button("重新探测") { Task { await check() } }
                    .disabled(isChecking)
            }

            Section {
                Button {
                    Task { await test() }
                } label: {
                    HStack {
                        if isTesting { ProgressView() }
                        Label("测试连接", systemImage: "bolt")
                    }
                }
                .disabled(isTesting)
                if let testResult {
                    switch testResult {
                    case .success(let message):
                        Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failure(let error):
                        Label(error.localizedDescription, systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    }
                }
            } footer: {
                Text("测试会通过 SSH 在服务器上执行一条轻量查询，验证客户端与数据库均可用。")
            }
        }
        .navigationTitle(conn.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await check() }
    }

    private func check() async {
        isChecking = true
        availability = await DatabaseService.shared.checkAvailability(for: conn.kind)
        isChecking = false
    }

    private func test() async {
        isTesting = true
        testResult = nil
        testResult = await DatabaseService.shared.testConnection(conn)
        isTesting = false
    }
}

// MARK: - 连接编辑器（新增 / 编辑）

struct ConnectionEditorView: View {
    let conn: DatabaseConnection?
    @ObservedObject var store: DatabaseConnectionStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var kind: DatabaseKind = .mysql
    @State private var host: String = "127.0.0.1"
    @State private var portText: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var database: String = ""
    @State private var showError = false
    @State private var errorMessage = ""

    private var isEditing: Bool { conn != nil }
    private var isMongoOrRedis: Bool { kind == .mongodb || kind == .redis }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("名称（如：生产 MySQL）", text: $name)
                    Picker("类型", selection: $kind) {
                        ForEach(DatabaseKind.allCases) { k in
                            Text(k.title).tag(k)
                        }
                    }
                    .onChange(of: kind) { _, newKind in
                        if portText.isEmpty || Int(portText) == nil { portText = String(newKind.defaultPort) }
                    }
                }
                .onAppear { initialize() }

                Section {
                    TextField("主机", text: $host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("端口", text: $portText).keyboardType(.numberPad)
                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("密码 / 口令", text: $password)
                    TextField(isMongoOrRedis ? "认证库 / db 索引（可选）" : "默认数据库（可选）", text: $database)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("连接参数")
                } footer: {
                    Text(isMongoOrRedis
                         ? "MongoDB 填认证库（留空为 admin）；Redis 填 db 索引（如 0）。"
                         : "留空则连接后手动选择数据库。")
                }

                if showError {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).font(.caption)
                    }
                }
            }
            .navigationTitle(isEditing ? "编辑连接" : "添加连接")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }.fontWeight(.semibold)
                }
            }
        }
    }

    private func initialize() {
        if let conn {
            name = conn.name; kind = conn.kind; host = conn.host
            portText = String(conn.port); username = conn.username
            database = conn.database; password = store.password(for: conn)
        } else {
            portText = String(DatabaseKind.mysql.defaultPort)
        }
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "请填写名称"; showError = true; return
        }
        let port = Int(portText) ?? kind.defaultPort
        guard port > 0, port <= 65535 else {
            errorMessage = "端口无效"; showError = true; return
        }
        let ok: Bool
        if let conn {
            var updated = conn
            updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.kind = kind; updated.host = host; updated.port = port
            updated.username = username; updated.database = database
            ok = store.update(updated, password: password.isEmpty ? nil : password)
        } else {
            let new = DatabaseConnection(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                kind: kind, host: host, port: port,
                username: username, database: database
            )
            ok = store.add(new, password: password)
        }
        if ok { dismiss() }
        else { errorMessage = "保存失败（可能是钥匙串写入错误）"; showError = true }
    }
}

// MARK: - 类型颜色

extension DatabaseView {
    static func kindColor(_ kind: DatabaseKind) -> Color {
        switch kind {
        case .mysql: return .orange
        case .postgresql: return .blue
        case .mongodb: return .green
        case .redis: return .red
        }
    }
}

// MARK: - 数据浏览页（库→表→数据 + 查询）

struct DatabaseBrowserView: View {
    @ObservedObject var store: DatabaseConnectionStore

    @State private var selectedConnectionID: UUID?
    @State private var databases: [DatabaseItem] = []
    @State private var isLoadingDatabases = false
    @State private var loadError: String?
    @State private var selectedDatabase: String?
    @State private var tables: [DatabaseItem] = []
    @State private var isLoadingTables = false
    @State private var selectedTable: String?
    @State private var showQuery = false

    private var selectedConnection: DatabaseConnection? {
        store.connections.first { $0.id == selectedConnectionID }
    }

    var body: some View {
        List {
            // 连接选择
            Section("数据库") {
                if store.connections.isEmpty {
                    Text("请先在「连接」页添加一条数据库连接")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("连接", selection: $selectedConnectionID) {
                        Text("选择连接...").tag(nil as UUID?)
                        ForEach(store.connections) { conn in
                            Text(conn.name).tag(conn.id as UUID?)
                        }
                    }
                    .onChange(of: selectedConnectionID) { _, _ in resetNavigation(); Task { await loadDatabases() } }
                }
            }

            // 库列表
            if selectedConnection != nil {
                Section {
                    if isLoadingDatabases {
                        HStack { ProgressView(); Text("正在读取数据库列表...").foregroundStyle(.secondary) }
                    } else if let loadError {
                        Label(loadError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).font(.caption)
                        Button("重试") { Task { await loadDatabases() } }
                    } else if databases.isEmpty {
                        Text("未读取到数据库").foregroundStyle(.secondary)
                    } else {
                        ForEach(databases) { db in
                            Button {
                                selectedDatabase = db.name
                                Task { await loadTables(for: db.name) }
                            } label: {
                                HStack {
                                    Image(systemName: "cylinder").foregroundStyle(.tint)
                                    Text(db.name)
                                    if let detail = db.detail {
                                        Spacer()
                                        Text(detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                } header: {
                    HStack {
                        Text(selectedConnection?.kind == .redis ? "数据库索引 (db)" : "数据库")
                        Spacer()
                        if selectedConnection != nil {
                            Button { Task { await loadDatabases() } } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                    }
                }
            }

            // 表 / 集合 / Key 列表
            if selectedDatabase != nil {
                Section {
                    if isLoadingTables {
                        HStack { ProgressView(); Text("正在读取列表...").foregroundStyle(.secondary) }
                    } else if tables.isEmpty {
                        Text("（空）").foregroundStyle(.secondary)
                    } else {
                        ForEach(tables) { table in
                            NavigationLink {
                                DataBrowserView(conn: selectedConnection!, database: selectedDatabase!, table: table.name)
                            } label: {
                                HStack {
                                    Image(systemName: tableSymbol).foregroundStyle(.secondary)
                                    Text(table.name)
                                    if let detail = table.detail {
                                        Spacer()
                                        Text(detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text(listSectionTitle)
                }
            }
        }
        .navigationTitle("数据浏览")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showQuery = true
                } label: {
                    Image(systemName: "terminal")
                }
                .disabled(selectedConnection == nil)
                .help("执行 SQL / 命令")
            }
        }
        .sheet(isPresented: $showQuery) {
            if let conn = selectedConnection {
                QueryView(conn: conn, database: selectedDatabase ?? conn.database)
            }
        }
        .onAppear { ensureSelection() }
    }

    private var listSectionTitle: String {
        guard let kind = selectedConnection?.kind else { return "" }
        switch kind {
        case .mysql, .postgresql: return "数据表"
        case .mongodb: return "集合"
        case .redis: return "键 (Keys)"
        }
    }

    private var tableSymbol: String {
        guard let kind = selectedConnection?.kind else { return "tablecells" }
        switch kind {
        case .mysql, .postgresql: return "tablecells"
        case .mongodb: return "doc.text"
        case .redis: return "key"
        }
    }

    private func ensureSelection() {
        if selectedConnectionID == nil, let first = store.connections.first {
            selectedConnectionID = first.id
            Task { await loadDatabases() }
        }
    }

    private func resetNavigation() {
        selectedDatabase = nil
        tables = []
        selectedTable = nil
        loadError = nil
    }

    private func loadDatabases() async {
        guard let conn = selectedConnection else { return }
        isLoadingDatabases = true
        loadError = nil
        resetNavigation()
        let result = await DatabaseService.shared.listDatabases(conn)
        switch result {
        case .success(let items): databases = items
        case .failure(let error): loadError = error.localizedDescription; databases = []
        }
        isLoadingDatabases = false
    }

    private func loadTables(for database: String) async {
        guard let conn = selectedConnection else { return }
        isLoadingTables = true
        tables = []
        let result = await DatabaseService.shared.listTables(conn, database: database)
        switch result {
        case .success(let items): tables = items
        case .failure: tables = []
        }
        isLoadingTables = false
    }
}

// MARK: - 数据浏览（表内容）

struct DataBrowserView: View {
    let conn: DatabaseConnection
    let database: String
    let table: String

    @State private var result: QueryResult?
    @State private var isLoading = true
    @State private var error: String?
    @State private var showQuery = false

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在读取数据...").foregroundStyle(.secondary)
                }
            } else if let error {
                ContentUnavailableView {
                    Label("读取失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("重试") { Task { await load() } }
                }
            } else if let result {
                QueryResultView(result: result)
            }
        }
        .navigationTitle(table)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showQuery = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("自定义查询")
            }
        }
        .sheet(isPresented: $showQuery) {
            QueryView(conn: conn, database: database, initialStatement: initialSQL)
        }
        .task { await load() }
    }

    private var initialSQL: String {
        switch conn.kind {
        case .mysql: return "SELECT * FROM `\(database)`.`\(table)` LIMIT 100"
        case .postgresql: return "SELECT * FROM \"\(table)\" LIMIT 100"
        case .mongodb: return "db.getCollection('\(table)').find().limit(100).toArray()"
        case .redis: return "GET \(table)"
        }
    }

    private func load() async {
        isLoading = true
        error = nil
        let res = await DatabaseService.shared.previewData(conn, database: database, table: table)
        switch res {
        case .success(let queryResult): result = queryResult
        case .failure(let dbError): error = dbError.localizedDescription; result = nil
        }
        isLoading = false
    }
}

// MARK: - 查询结果表格

struct QueryResultView: View {
    let result: QueryResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !result.message.isEmpty {
                Text(result.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            if result.columns.isEmpty && result.rows.isEmpty {
                ContentUnavailableView("无数据", systemImage: "tablecells")
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Grid(alignment: .topLeading, horizontalSpacing: 1, verticalSpacing: 1) {
                        // 表头
                        GridRow {
                            ForEach(result.columns, id: \.self) { column in
                                Text(column)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(.secondarySystemGroupedBackground))
                            }
                        }
                        // 数据行
                        ForEach(result.rows.indices, id: \.self) { rowIndex in
                            GridRow {
                                ForEach(result.columns.indices, id: \.self) { colIndex in
                                    let value = colIndex < result.rows[rowIndex].count ? result.rows[rowIndex][colIndex] : ""
                                    Text(value)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.primary)
                                        .textSelection(.enabled)
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(rowIndex % 2 == 0 ? Color(.systemGroupedBackground) : Color.clear)
                                }
                            }
                        }
                    }
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                    .padding()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - 查询执行页

struct QueryView: View {
    let conn: DatabaseConnection
    let database: String
    let initialStatement: String

    init(conn: DatabaseConnection, database: String, initialStatement: String = "") {
        self.conn = conn
        self.database = database
        self.initialStatement = initialStatement
    }

    @Environment(\.dismiss) private var dismiss
    @State private var statement: String = ""
    @State private var result: QueryResult?
    @State private var error: String?
    @State private var isRunning = false
    @State private var copied = false

    private var placeholder: String {
        switch conn.kind {
        case .mysql, .postgresql: return "SELECT * FROM your_table LIMIT 100"
        case .mongodb: return "db.getCollection('name').find().limit(10).toArray()"
        case .redis: return "KEYS *"
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 输入区
                VStack(alignment: .leading, spacing: 8) {
                    Text(conn.kind.supportsSQL ? "SQL 语句" : "命令")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $statement)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100, maxHeight: 160)
                        .padding(8)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button("清空") { statement = "" }
                        Spacer()
                        Button {
                            Task { await runStatement() }
                        } label: {
                            HStack {
                                if isRunning { ProgressView() }
                                Label("执行", systemImage: "play.fill")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isRunning || statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding()
                .background(Color(.systemGroupedBackground))

                Divider()

                // 结果区
                Group {
                    if isRunning {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("正在执行...").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let error {
                        ContentUnavailableView {
                            Label("执行失败", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(error)
                        }
                    } else if let result {
                        QueryResultView(result: result)
                    } else {
                        ContentUnavailableView {
                            Label("准备就绪", systemImage: "chevron.left.forwardslash.chevron.right")
                        } description: {
                            Text("输入\(conn.kind.supportsSQL ? " SQL 语句" : "命令")后点击执行")
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("执行\(conn.kind.supportsSQL ? " SQL" : "命令")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let result {
                        Button {
                            UIPasteboard.general.string = flatResult(result)
                            copied = true
                        } label: {
                            Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                    }
                }
            }
            .onAppear {
                if statement.isEmpty {
                    statement = initialStatement.isEmpty ? "" : initialStatement
                }
            }
        }
    }

    private func runStatement() async {
        isRunning = true
        error = nil
        result = nil
        copied = false
        let res = await DatabaseService.shared.execute(conn, database: database, statement: statement)
        switch res {
        case .success(let queryResult): result = queryResult
        case .failure(let dbError): error = dbError.localizedDescription
        }
        isRunning = false
    }

    private func flatResult(_ result: QueryResult) -> String {
        var lines: [String] = []
        if !result.columns.isEmpty { lines.append(result.columns.joined(separator: "\t")) }
        for row in result.rows { lines.append(row.joined(separator: "\t")) }
        if lines.isEmpty { lines.append(result.message) }
        return lines.joined(separator: "\n")
    }
}
