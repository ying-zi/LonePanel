import SwiftUI
import UIKit

/// 用户「保存为编排模板」的本地存储。持久化到 UserDefaults（模板是配置文本，量小，
/// 跟随 App 本地数据，不跟服务器走——换设备可通过 iCloud 同步偏好，但模板本身仅本机）。
/// 用 ObservableObject 让模板列表页在保存/删除后即时刷新。
final class ComposeTemplateStore: ObservableObject {
    static let shared = ComposeTemplateStore()

    @Published private(set) var customTemplates: [ComposeTemplate] = []

    private let defaults = UserDefaults.standard
    private let storageKey = "com.lone.lonepanel.compose.custom.templates"

    private init() { load() }

    /// 保存 yml 为用户模板。同名覆盖（更新内容），返回保存后的模板。
    /// detail 可传来源说明（如「从容器生成」），不传则默认来自编排项目。
    @discardableResult
    func save(name: String, yaml: String, detail: String? = nil, symbol: String = "doc.text") -> ComposeTemplate {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = ComposeTemplate(
            id: "custom-\(UUID().uuidString)",
            name: trimmed.isEmpty ? L10n.t("Untitled template") : trimmed,
            detail: detail ?? L10n.t("Saved from a compose project"),
            symbol: symbol,
            yaml: yaml,
            isCustom: true
        )
        // 同名覆盖：删掉旧的再插入新的，避免列表里出现重名项。
        customTemplates.removeAll { $0.name == template.name }
        customTemplates.insert(template, at: 0)
        persist()
        return template
    }

    func remove(id: String) {
        customTemplates.removeAll { $0.id == id }
        persist()
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let list = try? JSONDecoder().decode([ComposeTemplate].self, from: data) else { return }
        customTemplates = list
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(customTemplates) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

/// 模板图标兜底：个别 SF Symbol 在特定 iOS 版本上可能渲染为空白。
/// 用 UIImage(systemName:) 探测，失效时回退到通用图标，避免出现「文字顶到最左、图标位空白」。
private func composeTemplateSymbol(_ name: String) -> String {
    UIImage(systemName: name) != nil ? name : "square.grid.2x2"
}

/// 编排模板（对标 1Panel「编排模板」）：选内置模板 → 编辑 yml → 选服务器目录 → 部署。
/// 本视图本身是 sheet，内部用 NavigationStack 承载「模板列表 → 编辑页」两级；
/// 目录选择用本地 .folderPicker，避免从 sheet 内再弹全局 sheet 把本页一起收起。
struct ComposeTemplateView: View {
    let onDeployed: () async -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var path = NavigationPath()
    @ObservedObject private var templateStore = ComposeTemplateStore.shared

    private let service = DockerService.shared

    var body: some View {
        NavigationStack(path: $path) {
            List {
                SwiftUI.Section {
                    Text(L10n.t("Choose a template to start. You can edit the compose content before deploying."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // 从已有（非编排）容器反向生成模板：补齐「普通容器没有 yml 可存」的缺口。
                SwiftUI.Section {
                    Button {
                        path.append(ComposeContainerPickerRoute())
                    } label: {
                        Label(L10n.t("Create template from container"), systemImage: "square.stack.3d.up.badge.plus")
                    }
                } footer: {
                    Text(L10n.t("Only containers not created by Compose are listed. For Compose containers, save a template from the project detail page instead."))
                        .font(.caption)
                }

                SwiftUI.Section {
                    ForEach(ComposeTemplate.builtins) { template in
                        Button {
                            path.append(template)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: composeTemplateSymbol(template.symbol))
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(template.name)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text(template.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(L10n.t("Built-in templates"))
                }

                // 用户从编排项目保存的模板：与内置模板一样可点开编辑部署，额外支持删除。
                if !templateStore.customTemplates.isEmpty {
                    SwiftUI.Section {
                        ForEach(templateStore.customTemplates) { template in
                            HStack(spacing: 12) {
                                Button {
                                    path.append(template)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: composeTemplateSymbol(template.symbol))
                                            .font(.title3)
                                            .foregroundStyle(.tint)
                                            .frame(width: 28)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(template.name)
                                                .font(.subheadline.weight(.medium))
                                                .foregroundStyle(.primary)
                                            Text(template.detail)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Button(role: .destructive) {
                                    templateStore.remove(id: template.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.subheadline)
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    } header: {
                        Text(L10n.t("My templates"))
                    } footer: {
                        Text(L10n.t("Templates saved from compose projects. Tap to edit and deploy, swipe or tap trash to remove."))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.t("Compose templates"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    CancelXButton()
                }
            }
            .navigationDestination(for: ComposeTemplate.self) { template in
                ComposeEditorView(
                    title: template.name,
                    projectName: template.id,
                    yaml: template.yaml,
                    onDeployed: {
                        dismiss()
                        await onDeployed()
                    }
                )
            }
            // 从已有容器创建模板：先选非编排容器，再进草稿保存页。
            .navigationDestination(for: ComposeContainerPickerRoute.self) { _ in
                ComposeContainerPickerView(path: $path)
            }
            .navigationDestination(for: ComposeDraft.self) { draft in
                ComposeDraftSaveView(draft: draft, store: templateStore)
            }
        }
        .presentationDetents([.large])
    }
}

/// 容器选择器入口路由（push 到 ComposeContainerPickerView）。
private struct ComposeContainerPickerRoute: Hashable {}

/// 从已有非编排容器反向生成模板：列出容器 → 选中 → 生成草稿 → 进保存页。
/// 只列非编排容器：编排容器已有 yml，去编排详情页存快照质量更高，反向生成反而丢信息。
private struct ComposeContainerPickerView: View {
    @Binding var path: NavigationPath

    private let service = DockerService.shared
    @State private var containers: [DockerContainer] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var selectedID: String?
    @State private var generateError: String?

    var body: some View {
        List {
            Section {
                Text(L10n.t("Only containers not created by Compose are listed. For Compose containers, save a template from the project detail page instead."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if isLoading {
                Section { HStack { ProgressView(); Text(L10n.t("Loading containers…")) } }
            } else if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.caption)
                }
            } else if containers.isEmpty {
                Section {
                    Text(L10n.t("No containers not created by Compose were found."))
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(containers) { container in
                        Button {
                            Task { await choose(container) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "cube")
                                    .font(.title3).foregroundStyle(.tint).frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(container.name)
                                        .font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                    Text(container.image)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if selectedID == container.id {
                                    ProgressView()
                                } else {
                                    Image(systemName: "chevron.right")
                                        .font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(selectedID != nil)
                    }
                } header: {
                    Text(L10n.t("Containers"))
                }
            }
            if let generateError {
                Section {
                    Label(generateError, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red).font(.caption)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("Create template from container"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let all = try await service.fetchContainers()
            containers = all.filter { !$0.isComposeManaged }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func choose(_ container: DockerContainer) async {
        selectedID = container.id
        generateError = nil
        defer { selectedID = nil }
        let result = await service.generateComposeDraft(containerID: container.id)
        switch result {
        case .success(let draft):
            // push 保存页（ComposeDraft 已 Identifiable+Hashable）。
            path.append(draft)
        case .failure(let error):
            generateError = error.localizedDescription
        }
    }
}

/// 草稿保存页：可改模板名 + 预览/编辑 yml + 查看反向还原注意事项，确认后存入「我的模板」。
private struct ComposeDraftSaveView: View {
    let draft: ComposeDraft
    let store: ComposeTemplateStore

    @State private var name: String
    @State private var yaml: String
    @Environment(\.dismiss) private var dismiss

    init(draft: ComposeDraft, store: ComposeTemplateStore) {
        self.draft = draft
        self.store = store
        _name = State(initialValue: draft.projectName)
        _yaml = State(initialValue: draft.yaml)
    }

    var body: some View {
        Form {
            SwiftUI.Section {
                TextField(L10n.t("Template name"), text: $name)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: {
                Text(L10n.t("Template name"))
            } footer: {
                Text(L10n.t("The template is saved on this device and can be found under My templates."))
            }

            SwiftUI.Section {
                TextEditor(text: $yaml)
                    .font(.caption2.monospaced())
                    .frame(minHeight: 260)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text(L10n.t("Compose content (docker-compose.yml)"))
            }

            if !draft.warnings.isEmpty {
                SwiftUI.Section {
                    ForEach(draft.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    Text(L10n.t("Review notes"))
                }
            }

            SwiftUI.Section {
                Button {
                    store.save(name: name, yaml: yaml, detail: L10n.t("Saved from a container"))
                    dismiss()
                } label: {
                    HStack {
                        Spacer()
                        Label(L10n.t("Save as template"), systemImage: "square.and.arrow.down")
                        Spacer()
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle(L10n.t("Save as template"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 通用编排编辑器：项目名 + yml 编辑 + 选服务器目录 + 部署。
/// 来源两种：内置模板 / 从容器反向生成的草稿。部署成功后的导航完全交给 onDeployed，
/// 编辑器自身不 dismiss——这样草稿流程可直接切到编排分区，而不必退回容器详情。
struct ComposeEditorView: View {
    let title: String
    let warnings: [String]
    let onDeployed: () async -> Void

    /// 非空表示「编辑现有项目」：直接覆盖该文件并 up，隐藏项目名/目录选择，按钮文案改为保存并重新部署。
    let existingConfigPath: String?

    // 目录选择由编辑器自己承载（本地 .folderPicker），模板 sheet / 容器 push 两种来源都适用。
    @State private var dirPickTarget: ModuleCoordinator.FileOpenTarget?
    @State private var projectName: String
    @State private var yaml: String
    @State private var directory = "/"
    @State private var isWorking = false
    @State private var errorMessage: String?

    private let service = DockerService.shared

    init(title: String,
         projectName: String,
         yaml: String,
         warnings: [String] = [],
         existingConfigPath: String? = nil,
         onDeployed: @escaping () async -> Void) {
        self.title = title
        self.warnings = warnings
        self.onDeployed = onDeployed
        self.existingConfigPath = existingConfigPath
        _projectName = State(initialValue: projectName)
        _yaml = State(initialValue: yaml)
    }

    var body: some View {
        Form {
            // 编辑现有项目：项目名与目录已随项目固定，不再让用户改（改了会变成另一个项目/文件）。
            if existingConfigPath == nil {
                SwiftUI.Section {
                    TextField(L10n.t("Project name"), text: $projectName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text(L10n.t("Project"))
                } footer: {
                    Text(L10n.t("Used as the compose project name (-p) and the saved file name."))
                }

                SwiftUI.Section {
                    Button {
                        dirPickTarget = ModuleCoordinator.shared.directoryPickTarget(
                            at: directory,
                            title: L10n.t("Choose deploy directory")
                        ) { picked in
                            directory = picked
                        }
                    } label: {
                        HStack {
                            Image(systemName: "folder").foregroundStyle(.tint)
                            Text(directory).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text(L10n.t("Deploy directory"))
                } footer: {
                    Text(L10n.t("The compose file will be saved to this directory on the server."))
                }
            }

            SwiftUI.Section {
                TextEditor(text: $yaml)
                    .font(.caption2.monospaced())
                    .frame(minHeight: 260)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text(L10n.t("Compose content (docker-compose.yml)"))
            }

            // 反向生成的注意事项（如端口冲突、未完全还原的字段）。
            if !warnings.isEmpty {
                SwiftUI.Section {
                    ForEach(warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text(L10n.t("Review notes"))
                }
            }

            if let error = errorMessage {
                SwiftUI.Section {
                    Label(error, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            SwiftUI.Section {
                Button {
                    Task { await deploy() }
                } label: {
                    HStack {
                        Spacer()
                        if isWorking {
                            ProgressView()
                        } else {
                            Label(existingConfigPath == nil
                                  ? L10n.t("Save and deploy")
                                  : L10n.t("Save and redeploy"),
                                  systemImage: "rocket")
                        }
                        Spacer()
                    }
                }
                .disabled(isWorking || !canDeploy)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .folderPicker(item: $dirPickTarget)
    }

    private var canDeploy: Bool {
        !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        DockerService.validResourceName(projectName.trimmingCharacters(in: .whitespacesAndNewlines)) &&
        !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func deploy() async {
        guard canDeploy else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        // 第一步：写 yml。编辑模式覆盖原文件；新建模式写到所选目录。
        let savedPath: String
        if let existing = existingConfigPath {
            let updated = await service.updateComposeFile(path: existing, yaml: yaml)
            switch updated {
            case .failure(let e): errorMessage = e.localizedDescription; return
            case .success: savedPath = existing
            }
        } else {
            let saved = await service.saveComposeFile(directory: directory, projectName: name, yaml: yaml)
            switch saved {
            case .failure(let e): errorMessage = e.localizedDescription; return
            case .success(let path): savedPath = path
            }
        }

        // 第二步：docker compose up -d。
        let result = await service.deployCompose(path: savedPath, project: name)
        switch result {
        case .failure(let e):
            errorMessage = e.localizedDescription
        case .success:
            // 导航交给调用方：模板流程关 sheet，草稿流程切编排分区。
            await onDeployed()
        }
    }
}
