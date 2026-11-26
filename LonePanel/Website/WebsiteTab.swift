import SwiftUI

/// Website 模块出口：向 App 层注册表提供 TabModule。
enum WebsiteTab {
    static let module = TabModule(
        id: "website",
        title: L10n.t("Website"),
        symbolName: "globe",
        view: AnyView(WebsiteView()),
        showsFloatingTerminal: true
    )
}
