import SwiftUI

/// 文件模块空壳页。模块私有内容放本目录，不引用其他模块。
struct FilesView: View {
    var body: some View {
        ModulePlaceholder(
            title: AppTab.files.title,
            systemImage: AppTab.files.symbolName,
            description: "SFTP 文件管理"
        )
    }
}
