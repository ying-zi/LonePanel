import SwiftUI

/// Website 模块出口：向 App 层注册表提供 TabModule。
enum WebsiteTab {
    static let module = TabModule(
        id: "website",
        title: "网站",
        symbolName: "globe",
        view: AnyView(WebsiteView()),
        showsFloatingTerminal: true
    )
}
