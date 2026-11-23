import Foundation
import CoreFoundation

/// 文本预览支持的编码。GB18030 覆盖 GBK/GB2312，是国内服务器日志与配置常见编码。
enum FileTextEncoding: String, CaseIterable, Identifiable, Hashable {
    case utf8 = "UTF-8"
    case utf16 = "UTF-16"
    case gb18030 = "GB18030 (中文)"
    case latin1 = "Latin-1"

    var id: String { rawValue }

    var stringEncoding: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .utf16: return .utf16
        case .gb18030:
            let cf = CFStringEncoding(CFStringEncodings.gb_18030_2000.rawValue)
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        case .latin1: return .isoLatin1
        }
    }
}

/// 文件在详情页的呈现类别。
enum RemoteFileKind {
    case directory
    case text
    case image
    case other

    init(file: RemoteFile) {
        if file.isDirectory {
            self = .directory
            return
        }
        let ext = (file.name as NSString).pathExtension.lowercased()
        let textExts: Set<String> = [
            "txt", "md", "markdown", "log", "json", "yml", "yaml", "toml", "ini", "conf",
            "cfg", "properties", "sh", "bash", "zsh", "py", "js", "ts", "jsx", "tsx",
            "html", "htm", "css", "scss", "xml", "svg", "csv", "swift", "c", "h", "cc",
            "cpp", "hpp", "java", "go", "rs", "rb", "php", "sql", "env", "gitignore"
        ]
        let imageExts: Set<String> = [
            "jpg", "jpeg", "png", "gif", "heic", "heif", "bmp", "webp", "tiff", "tif", "ico"
        ]
        if textExts.contains(ext) {
            self = .text
        } else if imageExts.contains(ext) {
            self = .image
        } else {
            self = .other
        }
    }
}

/// 路径层级的一级，供顶部路径摘要浮层逐级展示。
struct PathSegment: Identifiable, Hashable {
    let name: String
    let path: String
    var id: String { path }
}

/// 批量操作类型。
enum BatchOperation: String {
    case move = "移动"
    case copy = "复制"
}
