import SwiftUI

/// 应用根视图：遍历注册表装配 Tab，不硬编码任何具体模块视图。
/// 采用 iOS 26 Liquid Glass 浮动标签栏。
struct ContentView: View {
    @State private var selection: String = TabRegistry.modules.first?.id ?? ""

    var body: some View {
        TabView(selection: $selection) {
            ForEach(TabRegistry.modules) { module in
                module.view
                    .tabItem {
                        Label(module.title, systemImage: module.symbolName)
                    }
                    .tag(module.id)
            }
        }
        // iOS 26：TabBar 在下滑时收起、上滑时展开，让内容成为主角。
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}
