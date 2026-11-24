import Foundation

/// 终端相关偏好：悬浮按钮是否显示。
/// 全局记忆，不按服务器区分。
enum TerminalPreferences {
    private static let defaults = UserDefaults.standard
    private static let floatingKey = "com.lone.lonepanel.terminal.floating"

    /// 悬浮终端按钮是否显示。默认开。
    static var floatingEnabled: Bool {
        get {
            guard defaults.object(forKey: floatingKey) != nil else { return true }
            return defaults.bool(forKey: floatingKey)
        }
        set { defaults.set(newValue, forKey: floatingKey) }
    }
}
