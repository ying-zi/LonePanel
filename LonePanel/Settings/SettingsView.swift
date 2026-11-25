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

                // 终端：入口 + 悬浮开关合并为同一张卡片。终端是恒开底座，
                // 不再有"终端界面"开关；关闭所有内容模块后，App 直接进入终端。
                Section {
                    NavigationLink {
                        TerminalView(presentation: .pushed)
                    } label: {
                        Label("SSH 终端", systemImage: "terminal")
                    }
                    Toggle("显示悬浮终端按钮", isOn: $floatingEnabled)
                } header: {
                    Text("终端")
                } footer: {
                    Text("终端是全局底座能力，始终可用。关闭所有内容模块后，App 将直接进入 SSH 终端；悬浮按钮在多模块页面右下角提供快捷入口。")
                }

                // 模块管理：所有模块的开关。
                Section {
                    ForEach(toggleableModules, id: \.id) { item in
                        moduleToggleRow(item)
                    }
                } header: {
                    Text("模块管理")
                } footer: {
                    Text("关闭的模块将不再显示在底部栏。设置与底座能力（SSH 连接、通知、日志、终端）始终可用；全部关闭后，App 将直接进入 SSH 终端。")
                }
            }
            .navigationTitle("设置")
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
