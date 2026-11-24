import SwiftUI

/// Tab 模块的数据结构。根 Core 只定义类型，不认识任何具体模块。
/// 各功能模块导出一个 TabModule 实例，由 App 层的注册表统一登记。
struct TabModule: Identifiable {
    let id: String
    let title: String
    let symbolName: String
    /// 类型擦除，使 App 层无需知道具体视图类型。
    let view: AnyView
    /// 模块启动钩子：只由模块自己提供，App 层统一调用。
    /// 删除模块时连同注册表那一行一起删，项目仍可编译。
    let configure: () -> Void
    /// 该模块是否显示悬浮终端按钮。文件/设置不需要，容器/网站/数据库需要。
    let showsFloatingTerminal: Bool

    init(
        id: String,
        title: String,
        symbolName: String,
        view: AnyView,
        configure: @escaping () -> Void = {},
        showsFloatingTerminal: Bool = false
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.view = view
        self.configure = configure
        self.showsFloatingTerminal = showsFloatingTerminal
    }

    /// 便捷构造：接受任意 View，内部做类型擦除。
    init<Content: View>(
        id: String,
        title: String,
        symbolName: String,
        configure: @escaping () -> Void = {},
        showsFloatingTerminal: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            id: id,
            title: title,
            symbolName: symbolName,
            view: AnyView(content()),
            configure: configure,
            showsFloatingTerminal: showsFloatingTerminal
        )
    }
}
