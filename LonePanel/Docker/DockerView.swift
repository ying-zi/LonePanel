import SwiftUI

/// Docker 模块空壳页。模块私有内容放本目录，不引用其他模块。
struct DockerView: View {
    var body: some View {
        ModulePlaceholder(
            title: "Docker",
            systemImage: "shippingbox",
            description: "Docker 容器管理"
        )
    }
}
