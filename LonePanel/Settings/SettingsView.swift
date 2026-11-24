import SwiftUI

/// 设置模块入口。模块私有内容放本目录，不引用其他模块。
struct SettingsView: View {
    @AppStorage("com.lone.lonepanel.terminal.floating") private var floatingEnabled = true

    var body: some View {
        NavigationStack {
            List {
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
                    NavigationLink {
                        TerminalView()
                    } label: {
                        Label("SSH 终端", systemImage: "terminal")
                    }
                }

                Section {
                    Toggle("显示悬浮终端按钮", isOn: $floatingEnabled)
                } footer: {
                    Text("开启后，在 Docker、网站、数据库页面右下角显示终端快捷入口；文件和设置页不显示。")
                }
            }
            .navigationTitle("设置")
        }
    }
}
