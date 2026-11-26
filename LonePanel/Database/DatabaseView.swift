import SwiftUI

/// 数据库模块主视图：与 Docker 首页一致，顶部用分段控件切换「本地数据库 / 远程数据库」。
/// 本地 = 容器内数据库（1Panel 式主管理对象，命令在容器内执行）；远程 = 一项扩展连接能力。
/// 数据浏览 / 查询复用同一套底层命令，只是连接来源不同。
struct DatabaseView: View {
    enum Source: String, CaseIterable {
        case local = "Local databases"
        case remote = "Remote databases"
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
            .navigationTitle(L10n.t("Database"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 与 Docker 首页一致：标题位的分段切换。
                ToolbarItem(placement: .principal) {
                    Picker("Database source", selection: $source) {
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
                        Text(L10n.t("Discovering container databases...")).foregroundStyle(.secondary)
                    }
                } else if let discoverError {
                    Label(discoverError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.caption)
                    Button(L10n.t("Retry")) { Task { await discover() } }
                } else if instances.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.t("No database containers found"))
                            .font(.subheadline.weight(.semibold))
                        Text(L10n.t("After running MySQL / MariaDB / PostgreSQL / MongoDB / Redis in Docker on the server, they are listed here for direct management."))
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
                    Text(L10n.t("Container databases"))
                    Spacer()
                    Text("\(instances.count)").foregroundStyle(.secondary)
                }
            } footer: {
                Text(L10n.t("Commands run directly inside the container with no port mapping; credentials are read from container environment variables."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { Task { await discover() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isDiscovering)
                .help(L10n.t("Rediscover container databases"))
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
                        Text(L10n.t("No remote database added yet"))
                            .font(.subheadline.weight(.semibold))
                        Text(L10n.t("Remote databases connect to instances outside the server, complementing local container databases."))
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
                                Label(L10n.t("Delete"), systemImage: "trash")
                            }
                        }
                    }
                }
                Button {
                    showEditor = true
                } label: {
                    Label(L10n.t("Add remote database"), systemImage: "plus.circle")
                }
            } header: {
                HStack {
                    Text(L10n.t("Remote database connection"))
                    Spacer()
                    Text("\(store.connections.count)").foregroundStyle(.secondary)
                }
            } footer: {
                Text(L10n.t("Configuration is stored locally and passwords in Keychain; all commands still run through the current SSH server."))
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
            Section(L10n.t("Container info")) {
                LabeledContent("Name", value: instance.name)
                LabeledContent("Type", value: instance.kind.title)
                LabeledContent("Image", value: instance.imageName ?? "—")
                LabeledContent("Container ID", value: instance.containerID.map { String($0.prefix(12)) } ?? "—")
                LabeledContent("Status", value: instance.statusText ?? "—")
            }

            Section {
                LabeledContent("Execution mode", value: "Run inside container")
                LabeledContent("Username", value: instance.username.isEmpty ? "(No authentication)" : instance.username)
                LabeledContent {
                    Text(instance.database.isEmpty ? "(Automatic)" : instance.database)
                } label: {
                    Text(instance.kind == .redis ? "DB index" : "Default database")
                }
            } header: {
                Text(L10n.t("Connection info"))
            } footer: {
                Text(L10n.t("Commands run inside the container; credentials are read from environment variables and never written to local config."))
            }

            // 实例级管理：改管理员密码 + 用户管理（对标 1Panel 数据库管理）。
            InstanceAdminSection(conn: instance)
                .disabled(!instance.isRunning)

            if instance.isRunning {
                // 进详情直接列出并管理该实例下的数据库（对标 1Panel）。
                DatabaseListSection(conn: instance)
            } else {
                Section {
                    Label(L10n.t("Container is not running; cannot read databases"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } footer: {
                    Text(L10n.t("Start this container in the Docker module first, then manage its databases."))
                }
            }

            Section {
                NavigationLink {
                    DatabaseBrowserView(store: store, fixedConnection: instance)
                } label: {
                    Label(L10n.t("Browse data and run SQL"), systemImage: "tablecells")
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
                Label(L10n.t("User management"), systemImage: "person.2")
            }
            Button { showPassword = true } label: {
                Label(conn.kind == .redis ? "Reset requirepass" : "Reset admin password", systemImage: "key")
            }
        } header: {
            Label(L10n.t("Instance management"), systemImage: "wrench.and.screwdriver")
        } footer: {
            Text(L10n.t("After changing the password, local credentials are updated; rediscovery and future connections use the new password. User management supports viewing, creating, changing passwords and deleting."))
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
                    SecureField("New password", text: $password)
                    SecureField("Confirm new password", text: $confirm)
                    if mismatch {
                        Label(L10n.t("Passwords do not match"), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.caption)
                    }
                } header: {
                    Text(L10n.t("Admin password"))
                } footer: {
                    Text(conn.kind == .redis
                         ? "Runs CONFIG SET requirepass and attempts CONFIG REWRITE to persist it."
                         : "This will change the login password for \(adminLabel); the actual scope depends on the instance account.")
                }
                if let error {
                    Section { Label(error, systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.caption) }
                }
            }
            .navigationTitle(L10n.t("Reset password"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(L10n.t("Cancel")) { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("Save")) { Task { await submit() } }
                        .fontWeight(.semibold)
                        .disabled(isRunning || password.isEmpty || mismatch)
                }
            }
            .alert("Password updated", isPresented: $success) {
                Button(L10n.t("OK"), role: .cancel) { dismiss() }
            } message: {
                Text(L10n.t("Local credentials synced; future connections will use the new password."))
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
            error = "Passwords do not match"; return
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
                    HStack { ProgressView(); Text(L10n.t("Loading users...")).foregroundStyle(.secondary) }
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.caption)
                    Button(L10n.t("Retry")) { Task { await load() } }
                } else if users.isEmpty {
                    Text(L10n.t("No users found (this instance may not use user authentication)")).foregroundStyle(.secondary)
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
                                Label(L10n.t("Change password"), systemImage: "key")
                            }
                            .tint(.indigo)
                            Button(role: .destructive) { deleting = user } label: {
                                Label(L10n.t("Delete"), systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Label(L10n.t("User"), systemImage: "person.2")
                    Spacer()
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                }
            } footer: {
                Text(conn.kind == .redis
                     ? "Redis 6+ uses ACL users; older versions only support requirepass-change it in Reset Password."
                     : "Swipe a user to change password or delete. Do not delete admin accounts casually.")
            }

            Section {
                Button { showCreate = true } label: { Label(L10n.t("New user"), systemImage: "person.badge.plus") }
            }
        }
        .navigationTitle(L10n.t("User management"))
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
        .alert("Delete user", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        )) {
            Button(L10n.t("Cancel"), role: .cancel) { deleting = nil }
            Button(L10n.t("Delete"), role: .destructive) {
                if let user = deleting { Task { await remove(user) } }
            }
        } message: {
            Text("Delete user \"\(deleting?.name ?? "")\"? This cannot be undone.")
        }
        .alert("Operation result", isPresented: $showToast) {
            Button(L10n.t("OK"), role: .cancel) {}
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
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password)
                } header: { Text(L10n.t("Account")) }
                Section {
                    Toggle("Admin privileges", isOn: $isAdmin)
                    if !isAdmin {
                        TextField("Authorized database (leave empty to create account only)", text: $database)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } header: { Text(L10n.t("Permissions")) } footer: {
                    Text(conn.kind == .redis
                         ? "Create an ACL user with full key and command permissions."
                         : "Admin has full privileges; regular users can be limited to a database.")
                }
                if let error {
                    Section { Label(error, systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.caption) }
                }
            }
            .navigationTitle(L10n.t("New user"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(L10n.t("Cancel")) { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("Create")) { Task { await submit() } }
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
                    Text("User: \(user.name)").foregroundStyle(.secondary)
                    SecureField("New password", text: $password)
                    SecureField("Confirm new password", text: $confirm)
                    if mismatch {
                        Label(L10n.t("Passwords do not match"), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.caption)
                    }
                }
                if let error {
                    Section { Label(error, systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.caption) }
                }
            }
            .navigationTitle(L10n.t("Change password"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(L10n.t("Cancel")) { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("Save")) { Task { await submit() } }
                        .fontWeight(.semibold)
                        .disabled(isRunning || password.isEmpty || mismatch)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func submit() async {
        guard password == confirm else { error = "Passwords do not match"; return }
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
                    Text(L10n.t("Loading databases...")).foregroundStyle(.secondary)
                }
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption)
                Button(L10n.t("Retry")) { Task { await load() } }
            } else if databases.isEmpty {
                Text(L10n.t("No databases to display for this instance")).foregroundStyle(.secondary)
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
                                Label(L10n.t("Delete"), systemImage: "trash")
                            }
                        }
                        if canRename {
                            Button {
                                renaming = db
                                renameText = db.name
                            } label: {
                                Label(L10n.t("Rename"), systemImage: "pencil")
                            }
                            .tint(.indigo)
                        }
                    }
                }
            }
            if canCreate {
                Button {
                    showCreate = true
                } label: {
                    Label(L10n.t("Add database"), systemImage: "plus.circle")
                }
            }
        } header: {
            HStack {
                Label(conn.kind == .redis ? "Database index (db)" : "Database", systemImage: "cylinder.split.1x2")
                Spacer()
                if canCreate {
                    Button { Task { await load() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        } footer: {
            if canCreate {
                Text(L10n.t("Adding a database also creates a dedicated user granted access to it. Swipe to rename or delete; tap to browse tables and data."))
            } else {
                Text(L10n.t("Redis uses fixed DB indexes; tap an index to browse / clear keys."))
            }
        }
        .task { await load() }
        .sheet(isPresented: $showCreate) {
            DatabaseCreateView(conn: conn) { message in
                present(message)
                await load()
            }
        }
        .sheet(item: $renaming) { db in
            DatabaseNameEditor(title: "Rename database",
                               name: $renameText,
                               confirmTitle: "Save",
                               conn: conn) { name in
                await DatabaseService.shared.renameDatabase(conn, from: db.name, to: name)
            } onDone: { message in
                present(message)
                await load()
            }
        }
        .alert("Delete database", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        )) {
            Button(L10n.t("Cancel"), role: .cancel) { deleting = nil }
            Button(L10n.t("Delete"), role: .destructive) {
                if let db = deleting { Task { await remove(db) } }
            }
        } message: {
            Text("Delete database \"\(deleting?.name ?? "")\"? Its tables and data will be deleted. This cannot be undone.")
        }
        .alert("Operation result", isPresented: $showActionResult) {
            Button(L10n.t("OK"), role: .cancel) {}
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

/// 新建数据库（一步到位）：填库名 + 专属用户名/密码，自动建库并把用户授权到该库。
/// 对齐 1Panel 的建库体验——库建好即可用这个账号连接，无需再去用户管理手动绑定。
private struct DatabaseCreateView: View {
    let conn: DatabaseConnection
    let onDone: (String) async -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var database = ""
    @State private var username = ""
    @State private var password = ""
    @State private var grantAll = false
    @State private var isRunning = false
    @State private var error: String?

    private var canSubmit: Bool {
        !database.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Database name (letters, digits, underscore)", text: $database)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text(L10n.t("Database"))
                } footer: {
                    Text(L10n.t("Only letters, digits and underscores, up to 64 characters."))
                }
                Section {
                    TextField("Username (leave empty to use the database name)", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text(L10n.t("Dedicated user"))
                } footer: {
                    Text(L10n.t("This account is created with the database and granted access only to it. The password is sent to the server only and never stored locally."))
                }
                Section {
                    Picker("Permission scope", selection: $grantAll) {
                        Text(L10n.t("This database only (recommended)")).tag(false)
                        Text(L10n.t("All databases (admin)")).tag(true)
                    }
                } header: {
                    Text(L10n.t("Grant"))
                } footer: {
                    Text(L10n.t("By default only the current database is granted, following least privilege. Choose admin for cross-database management."))
                }
                if let error {
                    Section {
                        Label(error, systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.caption)
                    }
                }
            }
            .navigationTitle(L10n.t("New database"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(L10n.t("Cancel")) { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("Create")) { Task { await submit() } }
                        .fontWeight(.semibold)
                        .disabled(isRunning || !canSubmit)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func submit() async {
        isRunning = true
        error = nil
        let db = database.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? db : username.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await DatabaseService.shared.createDatabaseWithUser(
            conn, database: db, username: user,
            password: password, grantAll: grantAll
        )
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
                    TextField("Database name (letters, digits, underscore)", text: $name)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text(L10n.t("Database name"))
                } footer: {
                    Text("Only letters, digits and underscores, up to 64 characters. \(conn.kind.title) will run the corresponding command on the server.")
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
                    Button(L10n.t("Cancel")) { dismiss() }
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
                        Text(L10n.t("No database connection yet"))
                            .font(.headline)
                        Text(L10n.t("Add a connection to browse tables, query data and run SQL in the app.\nThe database client must be installed on the server."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button(L10n.t("Add connection")) { showEditor = true }
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
                                Label(L10n.t("Delete"), systemImage: "trash")
                            }
                            Button {
                                editing = conn
                                showEditor = true
                            } label: {
                                Label(L10n.t("Edit"), systemImage: "pencil")
                            }
                            .tint(.indigo)
                        }
                    }
                } header: {
                    Text(L10n.t("Database connection"))
                } footer: {
                    Text(L10n.t("Connection config is stored locally and passwords in Keychain. All commands run through the current SSH server."))
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
                .help(L10n.t("Add connection"))
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
            Section(L10n.t("Connection info")) {
                LabeledContent("Name", value: conn.name)
                LabeledContent("Type", value: conn.kind.title)
                LabeledContent("Host", value: conn.endpoint)
                LabeledContent("Username", value: conn.username.isEmpty ? "(None)" : conn.username)
                LabeledContent("Default database", value: conn.database.isEmpty ? "(None)" : conn.database)
            }

            Section(L10n.t("Client")) {
                HStack(alignment: .top, spacing: 10) {
                    if isChecking {
                        ProgressView()
                        Text("Detecting \(conn.kind.clientCommand) ...")
                            .foregroundStyle(.secondary)
                    } else if let availability {
                        switch availability {
                        case .available(let version):
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(L10n.t("Client available")).foregroundStyle(.green)
                                Text(version).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        case .clientMissing:
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(L10n.t("Client not found")).foregroundStyle(.orange)
                                Text("\(conn.kind.clientCommand) is not installed on the server. Please install the client first.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        case .failed(let message):
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(L10n.t("Detection failed")).foregroundStyle(.red)
                                Text(message).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text(L10n.t("Not detected yet")).foregroundStyle(.secondary)
                    }
                }
                Button(L10n.t("Detect again")) { Task { await check() } }
                    .disabled(isChecking)
            }

            Section {
                Button {
                    Task { await test() }
                } label: {
                    HStack {
                        if isTesting { ProgressView() }
                        Label(L10n.t("Test Connection"), systemImage: "bolt")
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
                Text(L10n.t("Test runs a lightweight query over SSH to verify the client and database are available."))
            }

            // 实例级管理：改管理员密码 + 用户管理（对标 1Panel 数据库管理）。
            InstanceAdminSection(conn: conn)

            // 进详情直接列出并管理该连接下的数据库（对标 1Panel）。
            DatabaseListSection(conn: conn)

            Section {
                NavigationLink {
                    DatabaseBrowserView(store: store, fixedConnection: conn)
                } label: {
                    Label(L10n.t("Browse data and run SQL"), systemImage: "tablecells")
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
                Section(L10n.t("Basic Info")) {
                    TextField("Name (e.g. Production MySQL)", text: $name)
                    Picker("Type", selection: $kind) {
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
                    TextField("Host", text: $host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Port", text: $portText).keyboardType(.numberPad)
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password)
                    TextField(isMongoOrRedis ? "Auth DB / DB index (optional)" : "Default database (optional)", text: $database)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text(L10n.t("Connection parameters"))
                } footer: {
                    Text(isMongoOrRedis
                         ? "For MongoDB enter the auth DB (blank = admin); for Redis enter the DB index (e.g. 0)."
                         : "Leave empty to select a database manually after connecting.")
                }

                if showError {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).font(.caption)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit connection" : "Add connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(L10n.t("Cancel")) { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("Save")) { save() }.fontWeight(.semibold)
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
            errorMessage = "Enter a name"; showError = true; return
        }
        let port = Int(portText) ?? kind.defaultPort
        guard port > 0, port <= 65535 else {
            errorMessage = "Invalid port"; showError = true; return
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
        else { errorMessage = "Save failed (possibly a Keychain write error)"; showError = true }
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
                Section(L10n.t("Database")) {
                    if store.connections.isEmpty {
                        Text(L10n.t("Add a remote connection on the Database page first"))
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Connect", selection: $selectedConnectionID) {
                            Text(L10n.t("Select a connection...")).tag(nil as UUID?)
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
                        HStack { ProgressView(); Text(L10n.t("Loading database list...")).foregroundStyle(.secondary) }
                    } else if let loadError {
                        Label(loadError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).font(.caption)
                        Button(L10n.t("Retry")) { Task { await loadDatabases() } }
                    } else if databases.isEmpty {
                        Text(L10n.t("No databases found")).foregroundStyle(.secondary)
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
                        Text(selectedConnection?.kind == .redis ? "Database index (db)" : "Database")
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
                        HStack { ProgressView(); Text(L10n.t("Loading list...")).foregroundStyle(.secondary) }
                    } else if tables.isEmpty {
                        Text(L10n.t("(Empty)")).foregroundStyle(.secondary)
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
        .navigationTitle(L10n.t("Browse data"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showQuery = true
                } label: {
                    Image(systemName: "terminal")
                }
                .disabled(selectedConnection == nil)
                .help(L10n.t("Run SQL / command"))
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
        case .mysql, .postgresql: return "Tables"
        case .mongodb: return "Collections"
        case .redis: return "Keys"
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
                    Text(L10n.t("Loading data...")).foregroundStyle(.secondary)
                }
            } else if let error {
                ContentUnavailableView {
                    Label(L10n.t("Load failed"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button(L10n.t("Retry")) { Task { await load() } }
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
                .help(L10n.t("Custom query"))
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
                ContentUnavailableView("No data", systemImage: "tablecells")
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
                    Text(conn.kind.supportsSQL ? "SQL statement" : "Command")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $statement)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100, maxHeight: 160)
                        .padding(8)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button(L10n.t("Clear")) { statement = "" }
                        Spacer()
                        Button {
                            Task { await runStatement() }
                        } label: {
                            HStack {
                                if isRunning { ProgressView() }
                                Label(L10n.t("Run"), systemImage: "play.fill")
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
                            Text(L10n.t("Running...")).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let error {
                        ContentUnavailableView {
                            Label(L10n.t("Execution failed"), systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(error)
                        }
                    } else if let result {
                        QueryResultView(result: result)
                    } else {
                        ContentUnavailableView {
                            Label(L10n.t("Ready"), systemImage: "chevron.left.forwardslash.chevron.right")
                        } description: {
                            Text("Enter \(conn.kind.supportsSQL ? " SQL" : " command") then tap Run")
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("Run \(conn.kind.supportsSQL ? " SQL" : " command")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("Done")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let result {
                        Button {
                            UIPasteboard.general.string = flatResult(result)
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
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
