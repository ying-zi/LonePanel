import SwiftUI

/// 设置模块入口。底座设置 + 各模块注册的设置项 + 模块开关面板。
struct SettingsView: View {
    @AppStorage("com.lone.lonepanel.terminal.floating") private var floatingEnabled = true
    @ObservedObject private var visibility = ModuleVisibility.shared

    /// 从注册表汇总可供用户开关的内容模块（排除恒开底座：设置页）。
    private var toggleableModules: [(id: ModuleID, title: String, symbol: String)] {
        var list: [(id: ModuleID, title: String, symbol: String)] = []
        for module in TabRegistry.modules {
            guard let id = ModuleID(rawValue: module.id), !id.isCore else { continue }
            list.append((id, module.title, module.symbolName))
        }
        return list
    }

    var body: some View {
        NavigationStack {
            List {
                // 底座设置：服务器、缓存。
                Section {
                    NavigationLink {
                        ServersView()
                    } label: {
                        Label(L10n.t("My Servers"), systemImage: "server.rack")
                    }
                    NavigationLink {
                        CacheSettingsView()
                    } label: {
                        Label(L10n.t("Cache Management"), systemImage: "internaldrive")
                    }
                    NavigationLink {
                        LanguageSettingsView()
                    } label: {
                        Label(L10n.t("Language"), systemImage: "globe")
                    }
                } header: {
                    Text(L10n.t("General"))
                }

                // 模块注册的设置项：各模块自己提供，设置页只负责遍历展示。
                ForEach(TabRegistry.modules, id: \.id) { module in
                    if let section = module.settingsSection {
                        section
                    }
                }

                // 终端：入口 + 悬浮开关合并为同一张卡片。终端是恒开底座，
                // 不再有"终端界面"开关；关闭所有内容模块后，App 直接进入终端。
                Section {
                    NavigationLink {
                        TerminalView(presentation: .pushed)
                    } label: {
                        Label(L10n.t("SSH Terminal"), systemImage: "terminal")
                    }
                    Toggle("Show Floating Terminal Button", isOn: $floatingEnabled)
                } header: {
                    Text(L10n.t("Terminal"))
                } footer: {
                    Text(L10n.t("Terminal is a global base capability and is always available. With all content modules off, the app opens directly in the SSH terminal; the floating button offers quick access on multi-module pages."))
                }

                // 模块管理：所有模块的开关。
                Section {
                    ForEach(toggleableModules, id: \.id) { item in
                        moduleToggleRow(item)
                    }
                } header: {
                    Text(L10n.t("Module management"))
                } footer: {
                    Text(L10n.t("Disabled modules disappear from the bottom bar. Settings and base capabilities (SSH, notifications, logs, terminal) stay available; with all off, the app opens in the SSH terminal."))
                }
            }
            .navigationTitle(L10n.t("Settings"))
        }
    }

    private func moduleToggleRow(
        _ item: (id: ModuleID, title: String, symbol: String)
    ) -> some View {
        Toggle(isOn: Binding(
            get: { visibility.isEnabled(item.id) },
            set: { newValue in
                _ = visibility.set(item.id, enabled: newValue)
            }
        )) {
            Label(item.title, systemImage: item.symbol)
        }
    }
}
