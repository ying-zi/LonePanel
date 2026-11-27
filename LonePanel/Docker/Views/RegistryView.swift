import SwiftUI

/// 私有仓库 Registry 管理（对标 1Panel 镜像仓库）。
/// 登录/退出调用 DockerService，密码在诊断层打码；HTTP 不安全仓库只给配置指引，
/// 不自动改 daemon.json / 不重启 Docker，避免中断现有容器。
struct RegistryView: View {
    @Environment(\.dismiss) private var dismiss
    private let service = DockerService.shared

    @State private var loggedIn: [String] = []
    @State private var isLoading = false
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var isSubmitting = false
    @State private var error: String?
    @State private var success: String?
    @State private var showGuide = false
    @State private var guideServer = ""

    var body: some View {
        NavigationStack {
            List {
                // 已登录仓库。
                Section {
                    if isLoading {
                        HStack {
                            ProgressView()
                            Text(L10n.t("Loading…")).foregroundStyle(.secondary)
                        }
                    } else if loggedIn.isEmpty {
                        Text(L10n.t("No logged-in registries"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(loggedIn, id: \.self) { item in
                            HStack {
                                Label(item, systemImage: "shippingbox")
                                Spacer()
                                Button(role: .destructive) {
                                    Task { await logout(item) }
                                } label: {
                                    Image(systemName: "rectangle.portrait.and.arrow.right")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                } header: {
                    Text(L10n.t("Logged-in registries"))
                } footer: {
                    Text(L10n.t("Registry list is read from the server Docker config. If empty, a credential helper may be in use."))
                }

                // 登录表单。
                Section {
                    TextField(L10n.t("Registry address"), text: $server)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.URL)
                    TextField(L10n.t("Username"), text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                    HStack {
                        if showPassword {
                            TextField(L10n.t("Password"), text: $password)
                                .textContentType(.password)
                        } else {
                            SecureField(L10n.t("Password"), text: $password)
                                .textContentType(.password)
                        }
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                    Button {
                        Task { await login() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text(L10n.t("Login"))
                        }
                    }
                    .disabled(isSubmitting || server.isEmpty || username.isEmpty || password.isEmpty)
                } header: {
                    Text(L10n.t("Login to registry"))
                } footer: {
                    Text(L10n.t("Password is sent via docker login and masked in diagnostics. Spaces are not allowed."))
                }

                // HTTP 不安全仓库指引（只读，手动执行）。
                Section {
                    Button {
                        guideServer = server
                        showGuide = true
                    } label: {
                        Label(L10n.t("HTTP insecure registry guide"), systemImage: "questionmark.circle")
                    }
                    .disabled(server.isEmpty)
                } footer: {
                    Text(L10n.t("For HTTP registries, Docker requires insecure-registries config and a restart, which interrupts running containers. The App will not do this automatically; view the manual steps here."))
                }

                if let error {
                    Section {
                        Label(error, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
                if let success {
                    Section {
                        Label(success, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle(L10n.t("Registry"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
            }
            .task { await load() }
            .alert(L10n.t("HTTP insecure registry guide"), isPresented: $showGuide) {
                Button(L10n.t("OK"), role: .cancel) {}
            } message: {
                Text(DockerService.insecureRegistryGuide(server: guideServer))
            }
        }
    }

    private func load() async {
        isLoading = true
        error = nil
        loggedIn = await service.listRegistryLogins()
        isLoading = false
    }

    private func login() async {
        isSubmitting = true
        error = nil
        success = nil
        let result = await service.registryLogin(server: server, username: username, password: password)
        isSubmitting = false
        switch result {
        case .success:
            password = ""
            success = L10n.t("Login successful")
            await load()
        case .failure(let e):
            error = e.localizedDescription
        }
    }

    private func logout(_ item: String) async {
        isSubmitting = true
        error = nil
        success = nil
        let result = await service.registryLogout(server: item)
        isSubmitting = false
        switch result {
        case .success:
            success = L10n.f("Logged out: %@", item)
            await load()
        case .failure(let e):
            error = e.localizedDescription
        }
    }
}
