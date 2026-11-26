import SwiftUI
import UniformTypeIdentifiers

/// 语言管理：选择内置/自定义语言包、导入 JSON 语言包、导出翻译模板。
/// 支持 Telegram 式外部语言包：用户拿导出的英文模板翻译成任意语言再导入。
struct LanguageSettingsView: View {
    @ObservedObject private var store = LocalizationStore.shared
    @State private var showImporter = false
    @State private var importError: String?
    @State private var exportID: String?
    @State private var showExporter = false
    @State private var exportData: Data?
    @State private var confirmRemoveID: String?

    var body: some View {
        List {
            Section {
                // 语言即时切换：绑定 currentID，切换后所有文案立即重算。
                // 视图树重建只作用于内容区，sheet 宿主身份稳定（见 ContentView.contentArea）。
                Picker(L10n.t("Language"), selection: Binding(
                    get: { store.currentID },
                    set: { store.select($0) }
                )) {
                    ForEach(store.availablePacks, id: \.id) { pack in
                        Text(store.packName(for: pack.id)).tag(pack.id)
                    }
                }
                .pickerStyle(.inline)
            } footer: {
                Text(L10n.t("Built-in packs: English and Simplified Chinese; you can also import a custom language pack."))
            }

            // 自定义语言包管理
            if !store.customPacks.isEmpty {
                Section {
                    ForEach(store.customPacks) { pack in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pack.name)
                                Text("\(pack.strings.count) " + L10n.t("entries"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                exportID = pack.id
                                exportData = store.exportData(for: pack.id)
                                showExporter = true
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .buttonStyle(.borderless)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { confirmRemoveID = pack.id } label: {
                                Label(L10n.t("Delete"), systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text(L10n.t("Custom Language Packs"))
                }
            }

            Section {
                Button {
                    showImporter = true
                } label: {
                    Label(L10n.t("Import Language Pack"), systemImage: "square.and.arrow.down")
                }
                Button {
                    exportID = "en"
                    exportData = store.exportData(for: "en")
                    showExporter = true
                } label: {
                    Label(L10n.t("Export Translation Template"), systemImage: "doc.text")
                }
            } footer: {
                Text(L10n.t("Export the English template, translate the values into your language, then import the JSON back. Keys must stay in English."))
            }

            Section {
                Toggle(L10n.t("Sync via iCloud"), isOn: Binding(
                    get: { store.iCloudSyncEnabled },
                    set: { store.setiCloudSync($0) }
                ))
                .disabled(!store.iCloudAvailable)
                HStack {
                    Label {
                        Text(store.iCloudAvailable ? L10n.t("iCloud Sync Available") : L10n.t("iCloud Unavailable - Stored Locally"))
                    } icon: {
                        Image(systemName: store.iCloudAvailable ? "icloud.fill" : "icloud.slash")
                            .foregroundStyle(store.iCloudAvailable ? .green : .secondary)
                    }
                    .font(.caption)
                    Spacer()
                    if !store.iCloudAvailable {
                        Text(L10n.t("Local Only")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text(L10n.t("Turn on to sync language preference and custom packs via iCloud across your devices. Requires a paid developer account with iCloud enabled; sideloaded or free-signed builds always store everything locally."))
            }
        }
        .navigationTitle(L10n.t("Language"))
        .sheet(isPresented: $showImporter) {
            DocumentPicker { data in
                do {
                    let pack = try store.importPack(data: data)
                    store.select(pack.id)
                } catch {
                    importError = error.localizedDescription
                }
            }
        }
        .sheet(isPresented: $showExporter) {
            if let data = exportData {
                DocumentExporter(data: data, filename: "\(exportID ?? "language").json", isPresented: $showExporter)
            }
        }
        .alert(L10n.t("Import Failed"), isPresented: Binding(
            get: { importError != nil }, set: { if !$0 { importError = nil } }
        )) {
            Button(L10n.t("OK"), role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .confirmationDialog(L10n.t("Delete Language Pack"), isPresented: Binding(
            get: { confirmRemoveID != nil }, set: { if !$0 { confirmRemoveID = nil } }
        )) {
            Button(L10n.t("Delete"), role: .destructive) {
                if let id = confirmRemoveID { store.removePack(id: id) }
            }
        }
    }
}

// MARK: - 文件导入

private struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: (Data) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.json], asCopy: true)
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (Data) -> Void
        init(onPick: @escaping (Data) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first, let data = try? Data(contentsOf: url) else { return }
            onPick(data)
        }
    }
}

// MARK: - 文件导出

/// 系统分享面板。直接让 UIActivityViewController 作为 sheet 的 root 呈现——
/// 过去「空 VC + updateUIViewController 里 present」的写法在 VC 尚未进入 window 层级时
/// present 会静默失败，正是「导出无反应」的根因。
private struct DocumentExporter: UIViewControllerRepresentable {
    let data: Data
    let filename: String
    @Binding var isPresented: Bool

    func makeCoordinator() -> Coordinator { Coordinator(isPresented: $isPresented) }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? data.write(to: tmp, options: .atomic)
        let activity = UIActivityViewController(activityItems: [tmp], applicationActivities: nil)
        activity.completionWithItemsHandler = { _, _, _, _ in
            isPresented = false
        }
        return activity
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}

    final class Coordinator {
        @Binding var isPresented: Bool
        init(isPresented: Binding<Bool>) { _isPresented = isPresented }
    }
}
