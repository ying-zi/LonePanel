import SwiftUI

/// 数据库模块空壳页。模块私有内容放本目录，不引用其他模块。
struct DatabaseView: View {
    var body: some View {
        ModulePlaceholder(
            title: "数据库",
            systemImage: "cylinder.split.1x2",
            description: "数据库管理"
        )
    }
}
