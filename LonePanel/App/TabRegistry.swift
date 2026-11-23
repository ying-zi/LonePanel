import SwiftUI

/// Tab 注册表：整个 App 唯一登记具体模块的地方。
/// 删除任意模块时，只需删除该模块目录 + 删除下方对应一行，项目仍可编译。
enum TabRegistry {
    static let modules: [TabModule] = [
        WebsiteTab.module,
        DockerTab.module,
        DatabaseTab.module,
        FilesTab.module,
        SettingsTab.module,
    ]
}
