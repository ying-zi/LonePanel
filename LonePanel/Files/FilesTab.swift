import SwiftUI

/// Files 模块出口：向 App 层注册表提供 TabModule。
enum FilesTab {
    static let module = TabModule(
        id: "files",
        title: "Files",
        symbolName: "folder",
        view: AnyView(FilesView())
    )
}
