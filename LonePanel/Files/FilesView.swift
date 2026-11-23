import SwiftUI

/// 文件模块根视图：直接承载原生 SFTP 文件浏览器。
/// 模块私有逻辑在 Files/Core 与 Files/Browser 内，不引用其他功能模块。
struct FilesView: View {
    var body: some View {
        FileBrowserView()
    }
}
