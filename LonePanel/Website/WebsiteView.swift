import SwiftUI

/// 网站模块空壳页。模块私有内容放本目录，不引用其他模块。
struct WebsiteView: View {
    var body: some View {
        ModulePlaceholder(
            title: "网站",
            systemImage: "globe",
            description: "网站管理"
        )
    }
}
