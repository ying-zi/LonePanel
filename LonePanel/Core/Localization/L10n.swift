import SwiftUI

/// 便捷本地化入口。源码里的字符串字面量保持英文（源语言 key），
/// 调用 L10n.t 会按当前语言包返回译文；查不到时回退英文原文。
enum L10n {
    /// 当前 App 内语言对应的 Locale。日期/时间在 1Panel 里要跟 App 语言走，
    /// 而不是系统 locale（系统英文时切到中文包，日期仍会显示英文月份）。
    static var currentLocale: Locale {
        switch LocalizationStore.shared.currentID {
        case "zh-Hans": return Locale(identifier: "zh_CN")
        case "en":      return Locale(identifier: "en_US")
        default:        return Locale(identifier: LocalizationStore.shared.currentID)
        }
    }

    /// 列表/详情统一的日期时间格式：年月日 + 时分秒，跟随 App 内语言。
    static func dateTimeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = currentLocale
        f.dateStyle = .medium
        f.timeStyle = .medium   // 含秒（zh: HH:mm:ss / en: h:mm:ss a）
        return f.string(from: date)
    }

    static func t(_ key: String) -> String {
        LocalizationStore.shared.t(key)
    }

    /// 带参数的本地化：模板用 %@（顺序）或 %1$@ / %2$@（指定位置）占位。
    /// 用纯字符串替换实现，避免 String(format:) 把 Swift String 桥接给 %@ 时
    /// 在部分 iOS 版本上崩溃；参数数量与模板不符时也不会崩，只会留原占位符。
    static func f(_ key: String, _ args: String...) -> String {
        var out = LocalizationStore.shared.t(key)
        for (i, arg) in args.enumerated() {
            out = out.replacingOccurrences(of: "%\(i + 1)$@", with: arg)
        }
        for arg in args {
            if let range = out.range(of: "%@") {
                out.replaceSubrange(range, with: arg)
            }
        }
        return out
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
