import SwiftUI

/// Docker 模块出口：向 App 层注册表提供 TabModule。
enum DockerTab {
    static let module = TabModule(
        id: "docker",
        title: "Docker",
        symbolName: "shippingbox",
        view: AnyView(DockerView()),
        showsFloatingTerminal: true
    )
}
