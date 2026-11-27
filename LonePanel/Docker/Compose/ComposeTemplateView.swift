import SwiftUI
import UIKit

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

    private let service = DockerService.shared

    var body: some View {
        NavigationStack(path: $path) {
            List {
                SwiftUI.Section {
                    Text(L10n.t("Choose a template to start. You can edit the compose content before deploying."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.t("Compose templates"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("Cancel")) { dismiss() }
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
        }
        .presentationDetents([.large])
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
