import SwiftUI

/// 便捷本地化入口。源码里的字符串字面量保持英文（源语言 key），
/// 调用 L10n.t 会按当前语言包返回译文；查不到时回退英文原文。
enum L10n {
    static func t(_ key: String) -> String {
        LocalizationStore.shared.t(key)
    }
}

/// 自动跟随语言切换刷新的文本视图。用于 let 常量 / 非 body 直接求值的文案。
struct LocalizedText: View {
    let key: String
    @ObservedObject private var store = LocalizationStore.shared

    init(_ key: String) { self.key = key }

    var body: some View {
        Text(store.t(key))
    }
}

extension String {
    /// 直接对字符串做本地化，链式写法： "Delete".localized
    var localized: String { L10n.t(self) }
}
