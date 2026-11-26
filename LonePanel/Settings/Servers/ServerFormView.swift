import SwiftUI

/// 添加 / 编辑服务器表单。认证方式切换时动态展开对应字段，
/// 底部「测试连接」执行真实 SSH 握手并展示成功或具体失败原因。
struct ServerFormView: View {
    private let server: Server?
    private let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var host: String
    @State private var portText: String
    @State private var username: String
    @State private var authKind: ServerAuthKind
    @State private var password: String = ""
    @State private var privateKeyPEM: String = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var testError: String?
    @State private var errorMessage: String?

    init(server: Server?, onSaved: @escaping () -> Void) {
        self.server = server
        self.onSaved = onSaved
        _name = State(initialValue: server?.name ?? "")
        _host = State(initialValue: server?.host ?? "")
        _portText = State(initialValue: server.map { String($0.port) } ?? "22")
        _username = State(initialValue: server?.username ?? "")
        _authKind = State(initialValue: server?.authKind ?? .password)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.t("Server")) {
                    TextField(L10n.t("Name (Note)"), text: $name)
                    TextField(L10n.t("Address"), text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(L10n.t("Port"), text: $portText)
                    TextField("root", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section(L10n.t("Authentication")) {
                    Picker(L10n.t("Authentication"), selection: $authKind) {
                        Text(L10n.t("Password")).tag(ServerAuthKind.password)
                        Text(L10n.t("Private Key")).tag(ServerAuthKind.privateKey)
                    }
                    .pickerStyle(.segmented)

                    if authKind == .password {
                        SecureField(L10n.t("Password"), text: $password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        Text(L10n.t("OpenSSH Private Key (PEM, unencrypted)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $privateKeyPEM)
                            .frame(minHeight: 140)
                            .font(.system(.footnote, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                if let result = testResult {
                    Section(L10n.t("Test Result")) {
                        Text(result)
                            .font(.subheadline)
                            .foregroundStyle(result.hasPrefix(L10n.t("Connected")) ? Color.green : Color.red)
                            .textSelection(.enabled)
                    }
                }

                Section {
                    Button {
                        Task { await runTest() }
                    } label: {
                        HStack(spacing: 8) {
                            if testing { ProgressView() }
                            Text(L10n.t("Test Connection"))
                        }
                    }
                    .disabled(testing)
                }
            }
            .navigationTitle(server == nil ? L10n.t("Add Server") : L10n.t("Edit Server"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("Save")) { save() }
                }
            }
            .alert(L10n.t("Notice"), isPresented: errorAlertBinding) {
                Button(L10n.t("OK"), role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .alert(L10n.t("Connection Failed"), isPresented: testErrorAlertBinding) {
                Button(L10n.t("OK"), role: .cancel) { testError = nil }
            } message: {
                Text(testError ?? "")
            }
        }
    }

    private var port: Int? {
        Int(portText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 用户名留空时按 root 处理（绝大多数服务器默认用户）。UI 上仅作占位提示，
    /// 不把 root 写进输入框，避免用户误以为已填好；真正提交时才兜底。
    private var resolvedUsername: String {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "root" : trimmed
    }

    private func validate() -> Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              port != nil else {
            errorMessage = L10n.t("Enter name, address and port")
            return false
        }
        return true
    }

    /// 编辑时空凭证表示沿用钥匙串中的原值。
    private func resolvedCredential() throws -> SSHAuthCredential {
        switch authKind {
        case .password:
            if !password.isEmpty { return .password(password) }
            if let server, let stored = try? KeychainStore.load(server.credentialKey) {
                return .password(stored)
            }
            throw FormError.missingCredential(L10n.t("Enter password"))
        case .privateKey:
            if !privateKeyPEM.isEmpty { return .privateKey(privateKeyPEM) }
            if let server, let stored = try? KeychainStore.load(server.credentialKey) {
                return .privateKey(stored)
            }
            throw FormError.missingCredential(L10n.t("Enter private key"))
        }
    }

    private func runTest() async {
        guard validate() else { return }
        guard let port else { return }
        testing = true
        testResult = nil
        testError = nil
        defer { testing = false }

        do {
            let credential = try resolvedCredential()
            let message = try await SSHSession.test(
                host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                port: port,
                username: resolvedUsername,
                credential: credential
            )
            testResult = message
        } catch {
            // 统一翻译成人话，用系统原生 alert 展示，不暴露底层报错。
            testError = SSHSession.describe(error)
        }
    }

    private func save() {
        guard validate() else { return }
        guard let port else { return }

        let id = server?.id ?? UUID()
        let credentialKey = server?.credentialKey
            ?? SettingsServerSession.shared.credentialKey(for: id)

        do {
            switch authKind {
            case .password:
                if !password.isEmpty { try KeychainStore.save(password, for: credentialKey) }
            case .privateKey:
                if !privateKeyPEM.isEmpty { try KeychainStore.save(privateKeyPEM, for: credentialKey) }
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let model = Server(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port,
            username: resolvedUsername,
            authKind: authKind,
            credentialKey: credentialKey
        )
        SettingsServerSession.shared.upsert(model)
        onSaved()
        dismiss()
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var testErrorAlertBinding: Binding<Bool> {
        Binding(
            get: { testError != nil },
            set: { if !$0 { testError = nil } }
        )
    }
}

private enum FormError: LocalizedError {
    case missingCredential(String)

    var errorDescription: String? {
        switch self {
        case .missingCredential(let text): return text
        }
    }
}
