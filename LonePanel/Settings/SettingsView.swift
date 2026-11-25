import SwiftUI

/// 设置模块入口。底座设置 + 各模块注册的设置项 + 模块开关面板。
struct SettingsView: View {
    @AppStorage("com.lone.lonepanel.terminal.floating") private var floatingEnabled = true
    @ObservedObject private var visibility = ModuleVisibility.shared

    /// 从注册表汇总可供用户开关的模块（排除核心设置页）。
    private var toggleableModules: [(id: ModuleID, title: String, symbol: String, core: Bool)] {
        var list: [(id: ModuleID, title: String, symbol: String, core: Bool)] = []
        for module in TabRegistry.modules {
            guard let id = ModuleID(rawValue: module.id) else { continue }
            list.append((id, module.title, module.symbolName, id.isCore))
        }
        // 终端 UI 不占 Tab，单独补一项。
        list.append((.terminalUI, "终端界面", "terminal", false))
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
                        Label("我的服务器", systemImage: "server.rack")
                    }
                    NavigationLink {
                        CacheSettingsView()
                    } label: {
                        Label("缓存管理", systemImage: "internaldrive")
                    }
                } header: {
                    Text("通用")
                }

                // 模块注册的设置项：各模块自己提供，设置页只负责遍历展示。
                ForEach(TabRegistry.modules, id: \.id) { module in
                    if let section = module.settingsSection {
                        section
                    }
                }

                // 终端 UI 模块的设置入口：跟随开关显隐。
                if visibility.terminalUIEnabled {
                    Section {
                        NavigationLink {
                            TerminalView(presentation: .pushed)
                        } label: {
                            Label("SSH 终端", systemImage: "terminal")
                        }
                    } header: {
                        Text("终端")
                    }
                }

                // 悬浮终端开关：仅终端 UI 模块启用时有意义。
                if visibility.terminalUIEnabled {
                    Section {
                        Toggle("显示悬浮终端按钮", isOn: $floatingEnabled)
                    } footer: {
                        Text("开启后，在 Docker、网站、数据库页面右下角显示终端快捷入口。关闭终端界面模块后此开关隐藏。")
                    }
                }

                // 模块管理：所有模块的开关。
                Section {
                    ForEach(toggleableModules, id: \.id) { item in
                        moduleToggleRow(item)
                    }
                } header: {
                    Text("模块管理")
                } footer: {
                    Text("关闭的模块将不再显示在底部栏。设置与底座能力（SSH 连接、通知、日志）始终可用；至少保留一个模块。")
                }
            }
            .navigationTitle("设置")
        }
    }

    @ViewBuilder
    private func moduleToggleRow(
        _ item: (id: ModuleID, title: String, symbol: String, core: Bool)
    ) -> some View {
        if item.core {
            HStack {
                Label(item.title, systemImage: item.symbol)
                Spacer()
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
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
}
