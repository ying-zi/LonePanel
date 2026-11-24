import Foundation

/// 终端相关偏好：全局记忆，不按服务器区分。
enum TerminalPreferences {
    private static let defaults = UserDefaults.standard
    private static let floatingKey = "com.lone.lonepanel.terminal.floating"
    private static let fontSizeKey = "com.lone.lonepanel.terminal.fontSize"
    private static let wrapKey = "com.lone.lonepanel.terminal.autoWrap"

    /// 悬浮终端按钮是否显示。默认开。
    static var floatingEnabled: Bool {
        get {
            guard defaults.object(forKey: floatingKey) != nil else { return true }
            return defaults.bool(forKey: floatingKey)
        }
        set { defaults.set(newValue, forKey: floatingKey) }
    }

    /// 终端字号。默认 14（手机小屏上 12 太小）。
    static var fontSize: Double {
        get {
            guard defaults.object(forKey: fontSizeKey) != nil else { return 14 }
            return defaults.double(forKey: fontSizeKey)
        }
        set { defaults.set(newValue, forKey: fontSizeKey) }
    }

    /// 自动换行。默认开（折行）；关闭时用宽列 + 水平滚动看完整长行。
    static var autoWrap: Bool {
        get {
            guard defaults.object(forKey: wrapKey) != nil else { return true }
            return defaults.bool(forKey: wrapKey)
        }
        set { defaults.set(newValue, forKey: wrapKey) }
    }
}
