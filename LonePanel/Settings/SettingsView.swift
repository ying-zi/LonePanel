import SwiftUI

/// 设置模块空壳页。模块私有内容放本目录，不引用其他模块。
struct SettingsView: View {
    var body: some View {
        ModulePlaceholder(
            title: "设置",
            systemImage: "gearshape",
            description: "连接与偏好设置"
        )
    }
}
