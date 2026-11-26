import SwiftUI

/// 新建容器表单（对标 1Panel）：分段填写基本信息、端口、挂载、环境变量、高级选项，
/// 底部实时预览最终 docker run 命令。所有命令由 DockerService.buildRunCommand 统一构造。
struct ContainerCreateView: View {
    let onCreated: (String) async -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var spec = ContainerCreateSpec()
    @State private var images: [DockerImage] = []
    @State private var networks: [String] = ["bridge", "host", "none"]
    @State private var isRunning = false
    @State private var error: String?
    @State private var showImagePicker = false
    /// 本地目录选择目标：本表单本身是 sheet，必须用本地 .folderPicker 承载选择器，
    /// 才能做到「选完目录只关选择器、新建容器表单不收起」。
    @State private var mountPickTarget: ModuleCoordinator.FileOpenTarget?

    private let service = DockerService.shared

    var body: some View {
        NavigationStack {
            Form {
                basicSection
                portsSection
                mountsSection
                envSection
                advancedSection
                previewSection
                if let error {
                    Section {
                        Label(error, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red).font(.caption)
                    }
                }
            }
            .navigationTitle(L10n.t("New container"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("Create")) { Task { await submit() } }
                        .fontWeight(.semibold)
                        .disabled(isRunning || spec.validate() != nil)
                }
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
            TextField("Container name", text: $spec.name)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            HStack {
                TextField("Image (e.g. nginx:latest)", text: $spec.image)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button {
                    showImagePicker = true
                } label: {
                    Image(systemName: "photo.stack")
                }
                .buttonStyle(.borderless)
                .help(L10n.t("Choose from existing images"))
            }
            Toggle("Pull latest image before creating", isOn: $spec.pullImage)
            Picker("Network", selection: $spec.network) {
                ForEach(networks, id: \.self) { Text($0).tag($0) }
            }
            Picker("Restart Policy", selection: $spec.restartPolicy) {
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
                    TextField("Host", text: $port.hostPort)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 60)
                    Text(":")
                        .foregroundStyle(.secondary)
                    TextField("Container", text: $port.containerPort)
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
                            title: "Choose host directory"
                        ) { picked in
                            mount.hostPath = picked
                        }
                    } label: {
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(.tint)
                            Text(mount.hostPath.isEmpty ? "Tap to choose host directory" : mount.hostPath)
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
                        TextField("Container path (e.g. /data)", text: $mount.containerPath)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                        Toggle("Read only", isOn: $mount.readOnly)
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
            TextField("Memory limit (e.g. 512m / 1g)", text: $spec.memory)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("CPU limit (e.g. 0.5 / 2)", text: $spec.cpus)
                .keyboardType(.decimalPad)
            TextField("Hostname", text: $spec.hostname)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Working directory", text: $spec.workdir)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("ENTRYPOINT (optional, overrides image)", text: $spec.entrypoint)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Startup command and arguments (optional)", text: $spec.command)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Toggle("Privileged mode", isOn: $spec.privileged)
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

    // MARK: - 提交

    private func submit() async {
        guard spec.validate() == nil else { return }
        isRunning = true
        error = nil
        let result = await service.createContainer(spec)
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
                    Button(L10n.t("Cancel")) { dismiss() }
                }
            }
        }
    }
}
