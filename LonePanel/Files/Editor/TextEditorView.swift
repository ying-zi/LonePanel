import SwiftUI

/// 原生文本编辑器：系统 TextEditor + 取消/存储，遵循项目「原生 UI」约束。
/// 打开时读取远端 UTF-8 文本，存储时写回并失效缓存；空内容也能正常存储。
struct TextEditorView: View {
    let file: RemoteFile
    let model: FileBrowserModel
    /// 存储成功回调，用于关闭面板并刷新列表。
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @FocusState private var editorFocused: Bool

    private var hasChanges: Bool { draft != original }
    @State private var original: String = ""

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(L10n.t("Reading file…"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    TextEditor(text: $draft)
                        .font(.system(size: 15, design: .monospaced))
                        .focused($editorFocused)
                        .padding(.horizontal, 4)
                        .toolbar {
                            ToolbarItem(placement: .keyboard) {
                                HStack {
                                    Spacer()
                                    // 完成输入语义用勾（与全 App「操作已完成」一致），不用向下箭头/文字 Done。
                                    // 行为仍是收起键盘光标，不 dismiss 整个编辑器。
                                    Button { editorFocused = false } label: {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 17, weight: .bold))
                                            .foregroundStyle(.primary)
                                    }
                                    .accessibilityLabel(L10n.t("Done"))
                                }
                            }
                        }
                }
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("Save")) { Task { await save() } }
                        .disabled(isLoading || isSaving || !hasChanges)
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        guard let text = await model.readText(file) else {
            dismiss()
            return
        }
        draft = text
        original = text
        isLoading = false
        editorFocused = true
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let ok = await model.writeText(draft, to: file)
        guard ok else { return }
        onSaved()
        dismiss()
    }
}
