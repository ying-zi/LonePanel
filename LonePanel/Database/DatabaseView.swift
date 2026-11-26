import SwiftUI

/// 数据库模块主视图：与 Docker 首页一致，顶部用分段控件切换「本地数据库 / 远程数据库」。
/// 本地 = 容器内数据库（1Panel 式主管理对象，命令在容器内执行）；远程 = 一项扩展连接能力。
/// 数据浏览 / 查询复用同一套底层命令，只是连接来源不同。
struct DatabaseView: View {
    enum Source: String, CaseIterable {
        case local = "本地数据库"
        case remote = "远程数据库"
    }

    @State private var source: Source = .local
    @StateObject private var store = DatabaseConnectionStore.shared

    var body: some View {
        NavigationStack {
            Group {
                switch source {
                case .local:
                    LocalDatabaseListView(store: store)
                case .remote:
                    RemoteDatabaseListView(store: store)
                }
            }
            .navigationTitle("数据库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 与 Docker 首页一致：标题位的分段切换。
                ToolbarItem(placement: .principal) {
                    Picker("数据库来源", selection: $source) {
                        ForEach(Source.allCases, id: \.self) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SettingsGearButton()
                }
            }
        }
    }
}

/// 本地数据库：自动发现容器内的数据库实例。
struct LocalDatabaseListView: View {
    @ObservedObject var store: DatabaseConnectionStore

    @State private var instances: [DatabaseConnection] = []
    @State private var isDiscovering = false
    @State private var discoverError: String?

    var body: some View {
        List {
            Section {
                if isDiscovering {
                    HStack {
                        ProgressView()
                        Text("正在发现容器数据库...").foregroundStyle(.secondary)
                    }
                } else if let discoverError {
                    Label(discoverError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.caption)
                    Button("重试") { Task { await discover() } }
                } else if instances.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("未发现数据库容器")
                            .font(.subheadline.weight(.semibold))
                        Text("在服务器上用 Docker 运行 MySQL / MariaDB / PostgreSQL / MongoDB / Redis 后，这里会自动列出并直接管理容器内的数据库。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(instances) { instance in
                        NavigationLink {
                            ContainerDatabaseDetailView(instance: instance, store: store)
                        } label: {
                            DatabaseInstanceRow(conn: instance)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("容器数据库")
                    Spacer()
                    Text("\(instances.count)").foregroundStyle(.secondary)
                }
            } footer: {
                Text("命令直接在容器内执行，无需端口映射；凭据从容器环境变量读取。")
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { Task { await discover() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isDiscovering)
                .help("重新发现容器数据库")
            }
        }
        .refreshable { await discover() }
        .task { await discover() }
    }

    private func discover() async {
        isDiscovering = true
        discoverError = nil
        let result = await DatabaseService.shared.discoverContainerDatabases()
        switch result {
        case .success(let found): instances = found
        case .failure(let error):
            instances = []
            discoverError = error.localizedDescription
        }
        isDiscovering = false
    }
}

/// 远程数据库：管理数据库连接配置，是数据库管理中的一项能力。
struct RemoteDatabaseListView: View {
    @ObservedObject var store: DatabaseConnectionStore
    @State private var showEditor = false

    var body: some View {
        List {
            Section {
                if store.connections.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("尚未添加远程数据库")
                            .font(.subheadline.weight(.semibold))
                        Text("远程数据库用于连接服务器之外的实例，作为本地容器数据库的补充能力。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
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
                        }
                    }
                }
                Button {
                    showEditor = true
                } label: {
                    Label("添加远程数据库", systemImage: "plus.circle")
                }
            } header: {
                HStack {
                    Text("远程数据库连接")
                    Spacer()
                    Text("\(store.connections.count)").foregroundStyle(.secondary)
                }
            } footer: {
                Text("配置存在本机、口令存钥匙串；所有命令仍通过当前 SSH 服务器执行。")
            }
        }
        .sheet(isPresented: $showEditor) {
            ConnectionEditorView(conn: nil, store: store)
        }
    }
}

/// 容器数据库实例列表行：类型图标 + 名称/镜像 + 运行状态点。
private struct DatabaseInstanceRow: View {
    let conn: DatabaseConnection

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: conn.kind.symbolName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(DatabaseView.kindColor(conn.kind))
                .frame(width: 34, height: 34)
                .background(DatabaseView.kindColor(conn.kind).opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(conn.name).font(.body.weight(.semibold))
                Text("\(conn.kind.title) · \(conn.imageName ?? "")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 5) {
                Circle().frame(width: 7, height: 7)
                    .foregroundStyle(conn.isRunning ? .green : .orange)
                Text(conn.statusText ?? "").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// 容器数据库实例详情：展示实例信息，直接进入该实例的数据浏览。
/// 全程只读上下文参数，不写用户偏好、不污染全局连接选择。
private struct ContainerDatabaseDetailView: View {
    let instance: DatabaseConnection
    @ObservedObject var store: DatabaseConnectionStore

    var body: some View {
        List {
            Section("容器信息") {
                LabeledContent("名称", value: instance.name)
                LabeledContent("类型", value: instance.kind.title)
                LabeledContent("镜像", value: instance.imageName ?? "—")
                LabeledContent("容器 ID", value: instance.containerID.map { String($0.prefix(12)) } ?? "—")
                LabeledContent("状态", value: instance.statusText ?? "—")
            }

            Section {
                LabeledContent("执行方式", value: "容器内执行")
                LabeledContent("用户名", value: instance.username.isEmpty ? "（无认证）" : instance.username)
                LabeledContent {
                    Text(instance.database.isEmpty ? "（自动）" : instance.database)
                } label: {
                    Text(instance.kind == .redis ? "db 索引" : "默认库")
                }
            } header: {
                Text("连接信息")
            } footer: {
                Text("命令直接在容器内运行，凭据从容器环境变量读取，不写入本机配置。")
            }

            // 实例级管理：改管理员密码 + 用户管理（对标 1Panel 数据库管理）。
            InstanceAdminSection(conn: instance)
                .disabled(!instance.isRunning)

            if instance.isRunning {
                // 进详情直接列出并管理该实例下的数据库（对标 1Panel）。
                DatabaseListSection(conn: instance)
            } else {
                Section {
                    Label("容器未运行，无法读取数据库", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } footer: {
                    Text("请先在 Docker 模块启动该容器，再回来管理数据库。")
                }
            }

            Section {
                NavigationLink {
                    DatabaseBrowserView(store: store, fixedConnection: instance)
                } label: {
                    Label("数据浏览与执行 SQL", systemImage: "tablecells")
                }
                .disabled(!instance.isRunning)
            }
        }
        .navigationTitle(instance.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 实例级管理（改管理员密码 + 用户管理）

/// 数据库实例的管理入口：重置管理员密码、管理用户。放进任一实例详情页。
private struct InstanceAdminSection: View {
    let conn: DatabaseConnection
    @State private var showPassword = false

    var body: some View {
        Section {
            NavigationLink {
                UserManagementView(conn: conn)
            } label: {
                Label("用户管理", systemImage: "person.2")
            }
            Button { showPassword = true } label: {
                Label(conn.kind == .redis ? "重置 requirepass" : "重置管理员密码", systemImage: "key")
            }
        } header: {
            Label("实例管理", systemImage: "wrench.and.screwdriver")
        } footer: {
            Text("改密后会同步更新本地凭据，重新发现容器 / 下次连接仍使用新密码。用户管理支持查看、新建、改密与删除。")
        }
        .sheet(isPresented: $showPassword) {
            AdminPasswordView(conn: conn)
        }
    }
}

/// 重置管理员密码。确认密码一致后执行，成功后展示反馈。
private struct AdminPasswordView: View {
    let conn: DatabaseConnection
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirm = ""
    @State private var isRunning = false
    @State private var error: String?
    @State private var success = false

    private var mismatch: Bool { !confirm.isEmpty && password != confirm }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("新密码", text: $password)
                    SecureField("确认新密码", text: $confirm)
                    if mismatch {
                        Label("两次输入不一致", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.caption)
                    }
                } header: {
                    Text("管理员口令")
                } footer: {
                    Text(conn.kind == .redis
                         ? "将执行 CONFIG SET requirepass，并尝试 CONFIG REWRITE 持久化。"
                         : "将修改 \(adminLabel) 的登录口令，执行范围取决于该实例的实际账号。")
                }
                if let error {
                    Section { Label(error, systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.caption) }
                }
            }
            .navigationTitle("重置密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { Task { await submit() } }
                        .fontWeight(.semibold)
                        .disabled(isRunning || password.isEmpty || mismatch)
                }
            }
            .alert("密码已更新", isPresented: $success) {
                Button("好", role: .cancel) { dismiss() }
            } message: {
                Text("本地凭据已同步，后续连接将使用新密码。")
            }
        }
        .presentationDetents([.medium])
    }

    private var adminLabel: String {
        switch conn.kind {
        case .mysql: return "root"
        case .postgresql: return "postgres"
        case .mongodb: return "admin.root"
        case .redis: return "default"
        }
    }

    private func submit() async {
        guard password == confirm else {
            error = "两次输入不一致"; return
        }
        isRunning = true; error = nil
        let result = await DatabaseService.shared.resetAdminPassword(conn, newPassword: password)
        isRunning = false
        switch result {
        case .success: success = true
        case .failure(let e): error = e.localizedDescription
        }
    }
}

/// 用户管理：列出用户，支持新建、改密、删除。整页以 sheet 或 push 形式呈现。
private struct UserManagementView: View {
    let conn: DatabaseConnection

    @State private var users: [DatabaseItem] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var showCreate = false
    @State private var editingPassword: DatabaseItem?
    @State private var deleting: DatabaseItem?
    @State private var toast: String?
    @State private var showToast = false

    var body: some View {
        List {
            Section {
                if isLoading {
                    HStack { ProgressView(); Text("正在读取用户...").foregroundStyle(.secondary) }
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.caption)
                    Button("重试") { Task { await load() } }
                } else if users.isEmpty {
                    Text("未读取到用户（该实例可能未启用用户认证）").foregroundStyle(.secondary)
                } else {
                    ForEach(users) { user in
                        HStack {
                            Image(systemName: "person.fill").foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.name).font(.body)
                                if let detail = user.detail {
                                    Text(detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                editingPassword = user
                            } label: {
                                Label("改密", systemImage: "key")
                            }
                            .tint(.indigo)
                            Button(role: .destructive) { deleting = user } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Label("用户", systemImage: "person.2")
                    Spacer()
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                }
            } footer: {
                Text(conn.kind == .redis
                     ? "Redis 6+ 使用 ACL 用户；老版本仅支持 requirepass，请在重置密码中修改。"
                     : "左滑用户可修改密码或删除；管理员账号请勿随意删除。")
            }

            Section {
                Button { showCreate = true } label: { Label("新建用户", systemImage: "person.badge.plus") }
            }
        }
        .navigationTitle("用户管理")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(isPresented: $showCreate) {
            UserEditorView(conn: conn) { message in
                present(message); await load()
            }
        }
        .sheet(item: $editingPassword) { user in
            UserPasswordView(conn: conn, user: user) { message in
                present(message)
            }
        }
        .alert("删除用户", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        )) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) {
                if let user = deleting { Task { await remove(user) } }
            }
        } message: {
            Text("确定删除用户「\(deleting?.name ?? "")」？此操作不可撤销。")
        }
        .alert("操作结果", isPresented: $showToast) {
            Button("好", role: .cancel) {}
        } message: {
            Text(toast ?? "")
        }
    }

    private func load() async {
        isLoading = true; error = nil
        let result = await DatabaseService.shared.listUsers(conn)
        switch result {
        case .success(let items): users = items
        case .failure(let e): error = e.localizedDescription; users = []
        }
        isLoading = false
    }

    private func remove(_ user: DatabaseItem) async {
        let result = await DatabaseService.shared.deleteUser(conn, rawName: user.name)
        switch result {
        case .success(let message): present(message); await load()
        case .failure(let e): present(e.localizedDescription)
        }
    }

    private func present(_ message: String) { toast = message; showToast = true }
}

/// 新建用户：用户名 / 密码 / 授权库 / 是否管理员。
private struct UserEditorView: View {
    let conn: DatabaseConnection
    let onDone: (String) async -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var password = ""
    @State private var database = ""
    @State private var isAdmin = false
    @State private var isRunning = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("密码", text: $password)
                } header: { Text("账号") }
                Section {
                    Toggle("管理员权限", isOn: $isAdmin)
                    if !isAdmin {
                        TextField("授权数据库（留空为仅建账号）", text: $database)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } header: { Text("权限") } footer: {
                    Text(conn.kind == .redis
                         ? "新建 ACL 用户并授予全部 key 与命令权限。"
                         : "管理员拥有全部权限；普通用户可限定到某个库。")
                }
                if let error {
                    Section { Label(error, systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.caption) }
                }
            }
            .navigationTitle("新建用户")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("创建") { Task { await submit() } }
                        .fontWeight(.semibold)
                        .disabled(isRunning || username.isEmpty || password.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func submit() async {
        isRunning = true; error = nil
        let result = await DatabaseService.shared.createUser(
            conn, username: username, password: password,
            database: isAdmin ? "" : database, isAdmin: isAdmin
        )
        isRunning = false
        switch result {
        case .success(let message):
            dismiss(); await onDone(message)
        case .failure(let e): error = e.localizedDescription
        }
    }
}

/// 修改指定用户密码。
private struct UserPasswordView: View {
    let conn: DatabaseConnection
    let user: DatabaseItem
    let onDone: (String) async -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var confirm = ""
    @State private var isRunning = false
    @State private var error: String?

    private var mismatch: Bool { !confirm.isEmpty && password != confirm }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("用户：\(user.name)").foregroundStyle(.secondary)
                    SecureField("新密码", text: $password)
                    SecureField("确认新密码", text: $confirm)
                    if mismatch {
                        Label("两次输入不一致", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.caption)
                    }
                }
                if let error {
                    Section { Label(error, systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.caption) }
                }
            }
            .navigationTitle("修改密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { Task { await submit() } }
                        .fontWeight(.semibold)
                        .disabled(isRunning || password.isEmpty || mismatch)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func submit() async {
        guard password == confirm else { error = "两次输入不一致"; return }
        isRunning = true; error = nil
        let result = await DatabaseService.shared.changeUserPassword(conn, rawName: user.name, newPassword: password)
        isRunning = false
        switch result {
        case .success(let message): dismiss(); await onDone(message)
        case .failure(let e): error = e.localizedDescription
        }
    }
}

// MARK: - 库列表管理（详情页直接列出并增删改）

/// 详情页里的库列表：进入即加载现有数据库，支持新增 / 删除 / 重命名。
/// 这是对标 1Panel 的核心能力——进详情直接看到库并管理，而不是先跳到"数据浏览"。
private struct DatabaseListSection: View {
    let conn: DatabaseConnection
    @State private var databases: [DatabaseItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showCreate = false
    @State private var newName = ""
    @State private var renaming: DatabaseItem?
    @State private var renameText = ""
    @State private var deleting: DatabaseItem?
    @State private var actionMessage: String?
    @State private var showActionResult = false

    private var canCreate: Bool { conn.kind != .redis }
    private var canRename: Bool { conn.kind != .redis }
    private var canDelete: Bool { conn.kind != .redis }

    var body: some View {
        Section {
            if isLoading {
                HStack {
                    ProgressView()
                    Text("正在读取数据库...").foregroundStyle(.secondary)
                }
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption)
                Button("重试") { Task { await load() } }
            } else if databases.isEmpty {
                Text("该实例下暂无可显示的数据库").foregroundStyle(.secondary)
            } else {
                ForEach(databases) { db in
                    NavigationLink {
                        DatabaseBrowserView(store: DatabaseConnectionStore.shared,
                                            fixedConnection: conn,
                                            initialDatabase: db.name)
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
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if canDelete {
                            Button(role: .destructive) { deleting = db } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        if canRename {
                            Button {
                                renaming = db
                                renameText = db.name
                            } label: {
                                Label("重命名", systemImage: "pencil")
                            }
                            .tint(.indigo)
                        }
                    }
                }
            }
            if canCreate {
                Button {
                    newName = ""
                    showCreate = true
                } label: {
                    Label("添加数据库", systemImage: "plus.circle")
                }
            }
        } header: {
            HStack {
                Label(conn.kind == .redis ? "数据库索引 (db)" : "数据库", systemImage: "cylinder.split.1x2")
                Spacer()
                if canCreate {
                    Button { Task { await load() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        } footer: {
            if canCreate {
                Text("左滑数据库可重命名或删除；点进数据库可浏览表与数据。")
            } else {
                Text("Redis 使用固定 db 索引，可点进索引浏览 / 清空 Key。")
            }
        }
        .task { await load() }
        .sheet(isPresented: $showCreate) {
            DatabaseNameEditor(title: "新建数据库",
                               name: $newName,
                               confirmTitle: "创建",
                               conn: conn) { name in
                await DatabaseService.shared.createDatabase(conn, name: name)
            } onDone: { message in
                present(message)
                await load()
            }
        }
        .sheet(item: $renaming) { db in
            DatabaseNameEditor(title: "重命名数据库",
                               name: $renameText,
                               confirmTitle: "保存",
                               conn: conn) { name in
                await DatabaseService.shared.renameDatabase(conn, from: db.name, to: name)
            } onDone: { message in
                present(message)
                await load()
            }
        }
        .alert("删除数据库", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        )) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) {
                if let db = deleting { Task { await remove(db) } }
            }
        } message: {
            Text("确定删除数据库「\(deleting?.name ?? "")」？其中的表和数据会一并删除，此操作不可撤销。")
        }
        .alert("操作结果", isPresented: $showActionResult) {
            Button("好", role: .cancel) {}
        } message: {
            Text(actionMessage ?? "")
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        let result = await DatabaseService.shared.listDatabases(conn)
        switch result {
        case .success(let items): databases = items
        case .failure(let error): errorMessage = error.localizedDescription; databases = []
        }
        isLoading = false
    }

    private func remove(_ db: DatabaseItem) async {
        let result = await DatabaseService.shared.dropDatabase(conn, name: db.name)
        switch result {
        case .success(let message): present(message); await load()
        case .failure(let error): present(error.localizedDescription)
        }
    }

    private func present(_ message: String) {
        actionMessage = message
        showActionResult = true
    }
}

/// 库名输入编辑器（新建 / 重命名共用），内部完成校验与命令执行。
private struct DatabaseNameEditor: View {
    let title: String
    @Binding var name: String
    let confirmTitle: String
    let conn: DatabaseConnection
    let action: (String) async -> Result<String, DatabaseError>
    let onDone: (String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isRunning = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("数据库名（字母、数字、下划线）", text: $name)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("库名")
                } footer: {
                    Text("仅支持字母、数字、下划线，长度不超过 64 字符。\(conn.kind.title) 将在服务器端执行对应命令。")
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).font(.caption)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(confirmTitle) {
                        Task { await submit() }
                    }
                    .fontWeight(.semibold)
                    .disabled(isRunning || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func submit() async {
        isRunning = true
        error = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await action(trimmed)
        isRunning = false
        switch result {
        case .success(let message):
            dismiss()
            await onDone(message)
        case .failure(let dbError):
            error = dbError.localizedDescription
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

            // 实例级管理：改管理员密码 + 用户管理（对标 1Panel 数据库管理）。
            InstanceAdminSection(conn: conn)

            // 进详情直接列出并管理该连接下的数据库（对标 1Panel）。
            DatabaseListSection(conn: conn)

            Section {
                NavigationLink {
                    DatabaseBrowserView(store: store, fixedConnection: conn)
                } label: {
                    Label("数据浏览与执行 SQL", systemImage: "tablecells")
                }
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
    /// 容器实例直连：跳过连接选择，直接进入该实例的数据浏览。
    var fixedConnection: DatabaseConnection? = nil
    /// 从库列表点进来时预设的库，进入后直接展开其表/集合/Key。
    var initialDatabase: String? = nil

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
        if let fixedConnection { return fixedConnection }
        return store.connections.first { $0.id == selectedConnectionID }
    }

    var body: some View {
        List {
            // 连接选择：容器实例直连时跳过，不暴露连接切换。
            if fixedConnection == nil {
                Section("数据库") {
                    if store.connections.isEmpty {
                        Text("请先在「数据库」页添加一条远程连接")
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
        .onAppear {
            if fixedConnection != nil {
                // 容器实例直连：无需选择连接，直接加载该实例的库列表。
                Task {
                    await loadDatabases()
                    if let initialDatabase {
                        selectedDatabase = initialDatabase
                        await loadTables(for: initialDatabase)
                    }
                }
            } else {
                ensureSelection()
            }
        }
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
