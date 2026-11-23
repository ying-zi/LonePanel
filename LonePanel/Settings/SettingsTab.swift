import SwiftUI

/// Settings 模块出口：向 App 层注册表提供 TabModule。
/// 注意：SSH/SFTP/密钥/主题等五个 Tab 共用能力在根级 Core，不属于本模块。
enum SettingsTab {
    static let module = TabModule(
        id: "settings",
        title: "设置",
        symbolName: "gearshape",
        view: AnyView(SettingsView())
    )
}
