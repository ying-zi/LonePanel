import SwiftUI

/// 应用根视图：遍历注册表装配 Tab，不硬编码任何具体模块视图。
/// 采用 iOS 26 Liquid Glass 浮动标签栏。
struct ContentView: View {
    @State private var selection: String = TabRegistry.modules.first?.id ?? ""

    /// 用自定义 binding 拦截「点击的正是当前已选中 Tab」的情况：
    /// 系统不会改变 selection，但会调用 setter，借此广播回根请求。
    private var selectionBinding: Binding<String> {
        Binding(
            get: { selection },
            set: { newValue in
                if newValue == selection {
                    TabNavigationCenter.shared.requestReset(tabID: newValue)
                } else {
                    selection = newValue
                }
            }
        )
    }

    var body: some View {
        TabView(selection: selectionBinding) {
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
