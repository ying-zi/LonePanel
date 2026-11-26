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
            .navigationTitle("新建容器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("创建") { Task { await submit() } }
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
            TextField("容器名称", text: $spec.name)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            HStack {
                TextField("镜像（如 nginx:latest）", text: $spec.image)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button {
                    showImagePicker = true
                } label: {
                    Image(systemName: "photo.stack")
                }
                .buttonStyle(.borderless)
                .help("从现有镜像选择")
            }
            Toggle("创建前拉取最新镜像", isOn: $spec.pullImage)
            Picker("网络", selection: $spec.network) {
                ForEach(networks, id: \.self) { Text($0).tag($0) }
            }
            Picker("重启策略", selection: $spec.restartPolicy) {
                Text("不重启").tag("no")
                Text("总是").tag("always")
                Text("除非手动停止").tag("unless-stopped")
                Text("失败时").tag("on-failure")
            }
        } header: {
            Text("基本信息")
        } footer: {
            Text("镜像可手动填写，也可点图标从服务器上已有的镜像里选。勾选拉取会先执行 docker pull。")
        }
    }

    // MARK: - 端口映射

    private var portsSection: some View {
        Section {
            ForEach($spec.ports) { $port in
                HStack(spacing: 6) {
                    TextField("宿主", text: $port.hostPort)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 60)
                    Text(":")
                        .foregroundStyle(.secondary)
                    TextField("容器", text: $port.containerPort)
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
                Label("添加端口", systemImage: "plus.circle")
            }
        } header: {
            Text("端口映射")
        } footer: {
            Text("宿主端口 : 容器端口，可加多条。留空的条目不会被写入命令。")
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
                        ModuleCoordinator.shared.pickDirectory(
                            at: current,
                            title: "选择宿主目录"
                        ) { picked in
                            mount.hostPath = picked
                        }
                    } label: {
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(.tint)
                            Text(mount.hostPath.isEmpty ? "点此选择宿主目录" : mount.hostPath)
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
                        TextField("容器内路径（如 /data）", text: $mount.containerPath)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                        Toggle("只读", isOn: $mount.readOnly)
                            .labelsHidden()
                        Text("只读").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            .onDelete { spec.mounts.remove(atOffsets: $0) }
            Button {
                spec.mounts.append(ContainerCreateSpec.Mount())
            } label: {
                Label("添加挂载", systemImage: "plus.circle")
            }
        } header: {
            Text("目录挂载")
        } footer: {
            Text("点宿主目录行会从服务器文件里挑一个目录；两边都填绝对路径才会写入命令。")
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
                Label("添加环境变量", systemImage: "plus.circle")
            }
        } header: {
            Text("环境变量")
        }
    }

    // MARK: - 高级选项

    private var advancedSection: some View {
        Section {
            TextField("内存限制（如 512m / 1g）", text: $spec.memory)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("CPU 限制（如 0.5 / 2）", text: $spec.cpus)
                .keyboardType(.decimalPad)
            TextField("主机名", text: $spec.hostname)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("工作目录", text: $spec.workdir)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("ENTRYPOINT（可选，覆盖镜像）", text: $spec.entrypoint)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("启动命令及参数（可选）", text: $spec.command)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Toggle("特权模式", isOn: $spec.privileged)
        } header: {
            Text("高级选项")
        } footer: {
            Text("限制与命令留空即使用默认值。特权模式权限很高，仅在必要时开启。")
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
            Text("命令预览")
        } footer: {
            Text("这是将在服务器上执行的命令，确认无误后再点创建。")
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
            .navigationTitle("选择镜像")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}
