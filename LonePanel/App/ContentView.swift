import SwiftUI

/// 应用根视图：遍历注册表装配 Tab，不硬编码任何具体模块视图。
/// 采用 iOS 26 Liquid Glass 浮动标签栏。
struct ContentView: View {
    @State private var selection: String = TabRegistry.modules.first?.id ?? ""

    /// 用普通 $selection，不再拦截「再次点击当前 Tab」。
    /// 文件模块把导航栈底设为默认目录后，iOS 26 点当前 Tab 系统级 pop 到栈底，
    /// 落点天然就是默认目录，无需任何自定义 binding 拦截。
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
        // 底部 TabBar 常显：不随列表滚动收起，五个 Tab 始终可见。
    }
}
