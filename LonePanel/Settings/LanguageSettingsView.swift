import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// 语言管理：选择内置/自定义语言包、导入 JSON 语言包、导出翻译模板。
/// 支持 Telegram 式外部语言包：用户拿导出的英文模板翻译成任意语言再导入。
struct LanguageSettingsView: View {
    @ObservedObject private var store = LocalizationStore.shared
    @State private var showImporter = false
    @State private var importError: String?
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
                                if let data = store.exportData(for: pack.id) {
                                    SharePresenter.present(data: data, filename: "\(pack.id).json")
                                }
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
                    // 直接由 UIKit 顶层 VC present 系统分享面板。
                    // 旧实现把 UIActivityViewController 当作 SwiftUI .sheet 的 root：
                    // 分享面板自己也是 modal，套在 sheet 里呈现时机不可靠，用户点了没反应。
                    if let data = store.exportData(for: "en") {
                        SharePresenter.present(data: data, filename: "translation-template-en.json")
                    }
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
        .alert(L10n.t("Import Failed"), isPresented: Binding(
            get: { importError != nil }, set: { if !$0 { importError = nil } }
        )) {
            Button(L10n.t("OK"), role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        // 用 alert 而非 confirmationDialog：后者在 iPad 上是带箭头的 popover，
        // 锚点常指向已滚动的按钮导致箭头错位。普通居中 alert 无箭头，位置稳定。
        .alert(L10n.t("Delete Language Pack"), isPresented: Binding(
            get: { confirmRemoveID != nil }, set: { if !$0 { confirmRemoveID = nil } }
        )) {
            Button(L10n.t("Cancel"), role: .cancel) { confirmRemoveID = nil }
            Button(L10n.t("Delete"), role: .destructive) {
                if let id = confirmRemoveID { store.removePack(id: id) }
            }
        } message: {
            Text(L10n.t("This language pack will be removed from this device."))
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

// MARK: - 系统分享面板（导出）

/// 由 UIKit 最顶层的 ViewController 直接 present UIActivityViewController。
/// 这是系统分享面板最可靠的呈现方式：
/// - 不用 SwiftUI .sheet 包裹——分享面板本身是 modal，套一层 sheet 会出现「点了没反应」；
/// - 不用「空 VC + present」——空 VC 尚未进入 window 层级时 present 会静默失败；
/// - 写到临时目录再分享，文件名明确，用户可「存储到文件」或直接转发。
private enum SharePresenter {
    static func present(data: Data, filename: String) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? data.write(to: tmp, options: .atomic)
        let activity = UIActivityViewController(activityItems: [tmp], applicationActivities: nil)
        // iOS 26 多场景：取前台激活场景的 keyWindow，再沿 presented 链找到最顶层 VC。
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        // iPad / 大屏：分享面板需要锚点，否则 popover 崩溃或无处呈现。
        if let pop = activity.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
        top.present(activity, animated: true)
    }
}
