import SwiftUI

/// 设置模块入口。模块私有内容放本目录，不引用其他模块。
struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    ServersView()
                } label: {
                    Label("我的服务器", systemImage: "server.rack")
                }
            }
            .navigationTitle("设置")
        }
    }
}
