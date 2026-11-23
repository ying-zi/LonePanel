import SwiftUI

/// Tab 模块的数据结构。根 Core 只定义类型，不认识任何具体模块。
/// 各功能模块导出一个 TabModule 实例，由 App 层的注册表统一登记。
struct TabModule: Identifiable {
    let id: String
    let title: String
    let symbolName: String
    /// 类型擦除，使 App 层无需知道具体视图类型。
    let view: AnyView

    init(
        id: String,
        title: String,
        symbolName: String,
        view: AnyView
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.view = view
    }

    /// 便捷构造：接受任意 View，内部做类型擦除。
    init<Content: View>(
        id: String,
        title: String,
        symbolName: String,
        @ViewBuilder content: () -> Content
    ) {
        self.init(id: id, title: title, symbolName: symbolName, view: AnyView(content()))
    }
}
