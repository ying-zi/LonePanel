import SwiftUI

/// 新建容器（对标 1Panel）：两种模式——
/// - 表单：分段填写基本信息/端口/挂载/环境变量/高级选项，底部实时预览 docker run，逐字段 quote；
/// - 命令行：直接粘贴一条完整 docker run 命令，原样执行（由用户对命令原文负责）。
struct ContainerCreateView: View {
    /// 创建模式：表单逐字段构造，命令行原样执行。
    private enum CreateMode: String {
        case form
        case commandLine
    }

    /// 编辑现有容器时的上下文。nil 表示新建。
    /// Docker 不允许原地改配置，编辑=重建同名容器，故需记原 ID 与编辑前是否运行。
    struct EditContext {
        let originalID: String
        let name: String
        let wasRunning: Bool
    }

    let onCreated: (String) async -> Void
    @Environment(\.dismiss) private var dismiss

    /// 编辑模式的预填配置与注意事项；新建时均为默认/空。
    private let editContext: EditContext?
    private let initialWarnings: [String]
    @State private var mode: CreateMode = .form
    @State private var rawCommand = ""
    @State private var spec: ContainerCreateSpec
    @State private var images: [DockerImage] = []
    @State private var networks: [String] = ["bridge", "host", "none"]
    @State private var isRunning = false
    @State private var error: String?
    @State private var showImagePicker = false
    @State private var showRebuildConfirm = false
    /// 本地目录选择目标：本表单本身是 sheet，必须用本地 .folderPicker 承载选择器，
    /// 才能做到「选完目录只关选择器、新建容器表单不收起」。
    @State private var mountPickTarget: ModuleCoordinator.FileOpenTarget?

    private let service = DockerService.shared

    /// 新建入口（保持原有调用不变）。
    init(onCreated: @escaping (String) async -> Void) {
        self.onCreated = onCreated
        self.editContext = nil
        self.initialWarnings = []
        _spec = State(initialValue: ContainerCreateSpec())
        _mode = State(initialValue: .form)
        _rawCommand = State(initialValue: "")
    }

    /// 编辑入口：预填反向生成的 spec，锁定名称，提交走重建。
    init(editContext: EditContext, spec: ContainerCreateSpec, warnings: [String],
         onCreated: @escaping (String) async -> Void) {
        self.onCreated = onCreated
        self.editContext = editContext
        self.initialWarnings = warnings
        _spec = State(initialValue: spec)
        _mode = State(initialValue: .form)
        _rawCommand = State(initialValue: "")
    }

    private var isEditing: Bool { editContext != nil }

    var body: some View {
        NavigationStack {
            Form {
                // 编辑模式：顶部强警告——重建会丢未挂载的数据。
                if isEditing {
                    SwiftUI.Section {
                        Label(L10n.t("Editing a container requires recreating it. Data outside mounted paths (e.g. an unmounted database directory) will be permanently lost. Mounted volumes are preserved."),
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                    if !initialWarnings.isEmpty {
                        SwiftUI.Section {
                            ForEach(initialWarnings, id: \.self) { warning in
                                Label(warning, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                            }
                        } header: {
                            Text(L10n.t("Review notes"))
                        }
                    }
                }

                // 模式切换：表单 / 命令行。编辑模式隐藏（重建须用结构化 spec）。
                if !isEditing {
                    Picker(L10n.t("Creation mode"), selection: $mode) {
                        Text(L10n.t("Form")).tag(CreateMode.form)
                        Text(L10n.t("Command line")).tag(CreateMode.commandLine)
                    }
                    .pickerStyle(.segmented)
                }

                if mode == .form {
                    basicSection
                    portsSection
                    mountsSection
                    envSection
                    advancedSection
                    previewSection
                } else {
                    commandLineSection
                }

                if let error {
                    Section {
                        Label(error, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red).font(.caption)
                    }
                }
            }
            .navigationTitle(isEditing ? L10n.t("Edit container") : L10n.t("New container"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    CancelXButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isEditing ? L10n.t("Save and rebuild") : L10n.t("Create")) {
                        if isEditing { showRebuildConfirm = true } else { Task { await submit() } }
                    }
                    .fontWeight(.semibold)
                    .disabled(isRunning || !canSubmit)
                }
            }
            .alert(L10n.t("Recreate container"), isPresented: $showRebuildConfirm) {
                Button(L10n.t("Cancel"), role: .cancel) {}
                Button(L10n.t("Save and rebuild"), role: .destructive) {
                    Task { await submit() }
                }
            } message: {
                Text(L10n.t("The container will be stopped, backed up and recreated with the new settings. If creation fails, the original is restored. Data outside mounted paths will be lost."))
            }
            .sheet(isPresented: $showImagePicker) {
                ImagePickerView(images: images) { ref in
                    spec.image = ref
                    spec.pullImage = false
                }
                .presentationDetents([.medium, .large])
            }
            // 目录选择器挂在本表单（sheet）自己的层级：选完只关选择器，表单不收起。
            .folderPicker(item: $mountPickTarget)
            .task {
                async let img = try? service.fetchImages()
                async let net = service.fetchNetworks()
                images = (await img) ?? []
                let custom = await net
                // 合并固定网络与自定义网络，去重。
                var all = networks
                for n in custom where !all.contains(n) { all.append(n) }
                networks = all
            }
        }
        .presentationDetents([.large])
    }

    // MARK: - 基本信息

    private var basicSection: some View {
        Section {
            // 编辑模式锁定名称：重建必须同名，改了名就是另一个容器了。
            if isEditing {
                LabeledContent(L10n.t("Container name"), value: spec.name)
            } else {
                TextField(L10n.t("Container name"), text: $spec.name)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            HStack {
                TextField(L10n.t("Image (e.g. nginx:latest)"), text: $spec.image)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button {
                    showImagePicker = true
                } label: {
                    Image(systemName: "photo.stack")
                }
                .buttonStyle(.borderless)
                .help(L10n.t("Choose from existing images"))
            }
            Toggle(L10n.t("Pull latest image before creating"), isOn: $spec.pullImage)
            Picker(L10n.t("Network"), selection: $spec.network) {
                ForEach(networks, id: \.self) { Text($0).tag($0) }
            }
            Picker(L10n.t("Restart Policy"), selection: $spec.restartPolicy) {
                Text(L10n.t("Never restart")).tag("no")
                Text(L10n.t("Always")).tag("always")
                Text(L10n.t("Unless stopped manually")).tag("unless-stopped")
                Text(L10n.t("On failure")).tag("on-failure")
            }
        } header: {
            Text(L10n.t("Basic Info"))
        } footer: {
            Text(L10n.t("Enter the image manually or tap the icon to pick from images on the server. Checking Pull runs docker pull first."))
        }
    }

    // MARK: - 端口映射

    private var portsSection: some View {
        Section {
            ForEach($spec.ports) { $port in
                HStack(spacing: 6) {
                    TextField(L10n.t("Host"), text: $port.hostPort)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 60)
                    Text(":")
                        .foregroundStyle(.secondary)
                    TextField(L10n.t("Container"), text: $port.containerPort)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 60)
                    Picker("", selection: $port.proto) {
                        Text("TCP").tag("tcp")
                        Text("UDP").tag("udp")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 70)
                }
            }
            .onDelete { spec.ports.remove(atOffsets: $0) }
            Button {
                spec.ports.append(ContainerCreateSpec.PortMapping())
            } label: {
                Label(L10n.t("Add port"), systemImage: "plus.circle")
            }
        } header: {
            Text(L10n.t("Port Bindings"))
        } footer: {
            Text(L10n.t("Host port : container port. Add multiple. Empty entries are ignored."))
        }
    }

    // MARK: - 目录挂载

    private var mountsSection: some View {
        Section {
            ForEach($spec.mounts) { $mount in
                VStack(alignment: .leading, spacing: 6) {
                    // 宿主路径：显示当前值，点击调起文件模块选择目录并回传。
                    Button {
                        let current = mount.hostPath.isEmpty ? "/" : mount.hostPath
                        mountPickTarget = ModuleCoordinator.shared.directoryPickTarget(
                            at: current,
                            title: L10n.t("Choose host directory")
                        ) { picked in
                            mount.hostPath = picked
                        }
                    } label: {
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(.tint)
                            Text(mount.hostPath.isEmpty ? L10n.t("Tap to choose host directory") : mount.hostPath)
                                .foregroundStyle(mount.hostPath.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    HStack(spacing: 6) {
                        TextField(L10n.t("Container path (e.g. /data)"), text: $mount.containerPath)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                        Toggle(L10n.t("Read only"), isOn: $mount.readOnly)
                            .labelsHidden()
                        Text(L10n.t("Read only")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            .onDelete { spec.mounts.remove(atOffsets: $0) }
            Button {
                spec.mounts.append(ContainerCreateSpec.Mount())
            } label: {
                Label(L10n.t("Add mount"), systemImage: "plus.circle")
            }
        } header: {
            Text(L10n.t("Volume mounts"))
        } footer: {
            Text(L10n.t("Tap the host path row to pick a directory from server files. Both paths must be absolute to be written to the command."))
        }
    }

    // MARK: - 环境变量

    private var envSection: some View {
        Section {
            ForEach($spec.env) { $item in
                HStack(spacing: 6) {
                    TextField("KEY", text: $item.key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 70)
                    Text("=")
                        .foregroundStyle(.secondary)
                    TextField("VALUE", text: $item.value)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                }
            }
            .onDelete { spec.env.remove(atOffsets: $0) }
            Button {
                spec.env.append(ContainerCreateSpec.EnvVar())
            } label: {
                Label(L10n.t("Add environment variable"), systemImage: "plus.circle")
            }
        } header: {
            Text(L10n.t("Environment variables"))
        }
    }

    // MARK: - 高级选项

    private var advancedSection: some View {
        Section {
            TextField(L10n.t("Memory limit (e.g. 512m / 1g)"), text: $spec.memory)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField(L10n.t("CPU limit (e.g. 0.5 / 2)"), text: $spec.cpus)
                .keyboardType(.decimalPad)
            TextField(L10n.t("Hostname"), text: $spec.hostname)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField(L10n.t("Working directory"), text: $spec.workdir)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField(L10n.t("ENTRYPOINT (optional, overrides image)"), text: $spec.entrypoint)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField(L10n.t("Startup command and arguments (optional)"), text: $spec.command)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Toggle(L10n.t("Privileged mode"), isOn: $spec.privileged)
        } header: {
            Text(L10n.t("Advanced options"))
        } footer: {
            Text(L10n.t("Leave limits and command empty to use defaults. Privileged mode is powerful-enable only when necessary."))
        }
    }

    // MARK: - 命令预览

    private var previewSection: some View {
        Section {
            Text(DockerService.buildRunCommand(spec))
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .foregroundStyle(.tint)
        } header: {
            Text(L10n.t("Command preview"))
        } footer: {
            Text(L10n.t("This is the command to run on the server. Verify it before creating."))
        }
    }

    // MARK: - 命令行模式

    private var commandLineSection: some View {
        Section {
            TextEditor(text: $rawCommand)
                .font(.caption.monospaced())
                .frame(minHeight: 160)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .overlay(alignment: .topLeading) {
                    if rawCommand.isEmpty {
                        Text(L10n.t("Paste a docker run command, e.g. docker run -d --name web -p 80:80 nginx:latest"))
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                }
        } header: {
            Text(L10n.t("docker run command"))
        } footer: {
            Text(L10n.t("The command runs on the server as-is. Only a single docker run command is allowed; you are responsible for its content."))
        }
    }

    /// 提交按钮是否可用：随模式切换校验条件。
    private var canSubmit: Bool {
        switch mode {
        case .form: return spec.validate() == nil
        case .commandLine: return !rawCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: - 提交

    private func submit() async {
        guard canSubmit else { return }
        isRunning = true
        error = nil
        let result: Result<String, DockerError>
        if let ctx = editContext {
            // 编辑模式：重建（带回滚），名称锁定为原名。
            result = await service.recreateContainer(
                originalID: ctx.originalID,
                name: ctx.name,
                wasRunning: ctx.wasRunning,
                spec: spec
            )
        } else {
            switch mode {
            case .form: result = await service.createContainer(spec)
            case .commandLine: result = await service.createContainerFromCommand(rawCommand)
            }
        }
        isRunning = false
        switch result {
        case .success(let id):
            dismiss()
            await onCreated(id)
        case .failure(let e):
            error = e.localizedDescription
        }
    }
}

/// 镜像选择：列出服务器现有镜像，点选后回传 "仓库:标签" 引用。
private struct ImagePickerView: View {
    let images: [DockerImage]
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(images) { image in
                Button {
                    onPick(image.fullName)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(image.repository).font(.subheadline.weight(.medium))
                        Text(image.tag).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(L10n.t("Select image"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    CancelXButton()
                }
            }
        }
    }
}
