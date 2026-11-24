import SwiftUI

/// 应用根视图：遍历注册表装配 Tab，不硬编码任何具体模块视图。
/// 采用 iOS 26 Liquid Glass 浮动标签栏。
struct ContentView: View {
    @State private var selection: String = TabRegistry.modules.first?.id ?? ""

    /// 点击「当前已选中」的 Tab 时，系统不会改 selection，但会调用 setter。
    /// 借此拦截：文件模块回默认目录的意图交给单例 model 处理（其他模块仅正常切换）。
    private var selectionBinding: Binding<String> {
        Binding(
            get: { selection },
            set: { newValue in
                if newValue == selection {
                    FileBrowserModel.shared.handleCurrentTabReselected()
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
        // 底部 TabBar 常显：不随列表滚动收起，五个 Tab 始终可见。
    }
}
