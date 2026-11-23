import SwiftUI

/// 应用根视图：iOS 26 Liquid Glass 风格的浮动 TabBar。
/// 仅负责组装模块，不含任何业务逻辑。
struct ContentView: View {
    @State private var selection: AppTab = .website

    var body: some View {
        TabView(selection: $selection) {
            WebsiteView()
                .tabItem { Label(AppTab.website.title, systemImage: AppTab.website.symbolName) }
                .tag(AppTab.website)

            DockerView()
                .tabItem { Label(AppTab.docker.title, systemImage: AppTab.docker.symbolName) }
                .tag(AppTab.docker)

            DatabaseView()
                .tabItem { Label(AppTab.database.title, systemImage: AppTab.database.symbolName) }
                .tag(AppTab.database)

            FilesView()
                .tabItem { Label(AppTab.files.title, systemImage: AppTab.files.symbolName) }
                .tag(AppTab.files)

            SettingsView()
                .tabItem { Label(AppTab.settings.title, systemImage: AppTab.settings.symbolName) }
                .tag(AppTab.settings)
        }
        // iOS 26：TabBar 在下滑时收起、上滑时展开，让内容成为主角。
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}
