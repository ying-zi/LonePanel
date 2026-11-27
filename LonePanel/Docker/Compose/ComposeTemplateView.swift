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
    @State private var dirPickTarget: ModuleCoordinator.FileOpenTarget?

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
                ComposeTemplateEditView(
                    template: template,
                    dirPickTarget: $dirPickTarget,
                    onDeployed: onDeployed,
                    dismiss: dismiss
                )
            }
        }
        .folderPicker(item: $dirPickTarget)
        .presentationDetents([.large])
    }
}

/// 模板编辑页：项目名 + yml 编辑 + 选服务器目录 + 部署。
private struct ComposeTemplateEditView: View {
    let template: ComposeTemplate
    @Binding var dirPickTarget: ModuleCoordinator.FileOpenTarget?
    let onDeployed: () async -> Void
    let dismiss: DismissAction

    @State private var projectName: String
    @State private var yaml: String
    @State private var directory = "/"
    @State private var isWorking = false
    @State private var errorMessage: String?

    private let service = DockerService.shared

    init(template: ComposeTemplate,
         dirPickTarget: Binding<ModuleCoordinator.FileOpenTarget?>,
         onDeployed: @escaping () async -> Void,
         dismiss: DismissAction) {
        self.template = template
        self._dirPickTarget = dirPickTarget
        self.onDeployed = onDeployed
        self.dismiss = dismiss
        _projectName = State(initialValue: template.id)
        _yaml = State(initialValue: template.yaml)
    }

    var body: some View {
        Form {
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

            SwiftUI.Section {
                TextEditor(text: $yaml)
                    .font(.caption2.monospaced())
                    .frame(minHeight: 260)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text(L10n.t("Compose content (docker-compose.yml)"))
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
                            Label(L10n.t("Save and deploy"), systemImage: "rocket")
                        }
                        Spacer()
                    }
                }
                .disabled(isWorking || !canDeploy)
            }
        }
        .navigationTitle(template.name)
        .navigationBarTitleDisplayMode(.inline)
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
        // 第一步：写 yml 到服务器目录。
        let saved = await service.saveComposeFile(
            directory: directory,
            projectName: projectName.trimmingCharacters(in: .whitespacesAndNewlines),
            yaml: yaml
        )
        switch saved {
        case .failure(let e):
            errorMessage = e.localizedDescription
            return
        case .success(let path):
            // 第二步：docker compose up -d。
            let result = await service.deployCompose(
                path: path,
                project: projectName.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            switch result {
            case .failure(let e):
                errorMessage = e.localizedDescription
            case .success:
                dismiss()
                await onDeployed()
            }
        }
    }
}
