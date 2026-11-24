import SwiftUI

/// Database 模块出口：向 App 层注册表提供 TabModule。
enum DatabaseTab {
    static let module = TabModule(
        id: "database",
        title: "数据库",
        symbolName: "cylinder.split.1x2",
        view: AnyView(DatabaseView()),
        showsFloatingTerminal: true
    )
}
