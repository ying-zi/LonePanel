import Foundation
import SwiftUI

/// 导航层级节点：根或某一级目录。NavigationStack 的 path 使用，push 即进入子目录，
/// 系统自带返回箭头回到上一级，与系统「文件」App 的逐层浏览一致。
struct FileNode: Hashable, Identifiable {
    let path: String
    let title: String
    var id: String { path }
}

/// 视图模式：列表 / 图标网格（对齐系统「文件」App 的视图切换）。
enum FileViewMode: String, CaseIterable, Identifiable {
    case list = "列表"
    case grid = "图标"
    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .list: return "list.bullet"
        case .grid: return "square.grid.2x2"
        }
    }
}

/// 排序字段（对齐系统「文件」App 的排序菜单）。
enum FileSortOrder: String, CaseIterable, Identifiable {
    case name = "名称"
    case kind = "种类"
    case date = "修改日期"
    case size = "大小"
    var id: String { rawValue }
}

/// 文件呈现类别，决定系统图标与网格缩略图。
enum FileKind {
    case directory
    case image
    case text
    case code
    case archive
    case other

    init(file: RemoteFile) {
        if file.isDirectory {
            self = .directory
            return
        }
        if file.isSymlink {
            self = .other
            return
        }
        let ext = (file.name as NSString).pathExtension.lowercased()
        if Self.imageExts.contains(ext) { self = .image }
        else if Self.codeExts.contains(ext) { self = .code }
        else if Self.textExts.contains(ext) { self = .text }
        else if Self.archiveExts.contains(ext) { self = .archive }
        else { self = .other }
    }

    var systemImage: String {
        switch self {
        case .directory: return "folder.fill"
        case .image: return "photo"
        case .text: return "doc.text.fill"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .archive: return "doc.zipper"
        case .other: return "doc.fill"
        }
    }

    /// 系统文件 App 的图标配色：文件夹蓝、图像紫、代码蓝绿、归档橙，其余灰。
    var tint: Color {
        switch self {
        case .directory: return .blue
        case .image: return .purple
        case .text: return .secondary
        case .code: return .teal
        case .archive: return .orange
        case .other: return .secondary
        }
    }

    /// 系统 QuickLook 能否直接预览。归档与未知二进制不支持，改走系统分享并在下载中显示进度。
    static func supportsQuickLook(_ file: RemoteFile) -> Bool {
        if file.isDirectory || file.isSymlink { return false }
        let ext = (file.name as NSString).pathExtension.lowercased()
        if Self.archiveExts.contains(ext) { return false }
        let previewable = Self.imageExts
            .union(Self.textExts)
            .union(Self.codeExts)
            .union(["pdf", "rtf", "pages", "numbers", "key", "docx", "xlsx", "pptx"])
        return previewable.contains(ext)
    }

    private static let imageExts: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "bmp", "webp", "tiff", "tif", "ico"
    ]
    private static let codeExts: Set<String> = [
        "sh", "bash", "zsh", "py", "js", "ts", "jsx", "tsx", "swift", "c", "h", "cc",
        "cpp", "hpp", "java", "go", "rs", "rb", "php", "html", "htm", "css", "json",
        "yml", "yaml", "xml", "sql"
    ]
    private static let textExts: Set<String> = [
        "txt", "md", "markdown", "log", "toml", "ini", "conf", "cfg", "csv", "env"
    ]
    private static let archiveExts: Set<String> = [
        "zip", "tar", "gz", "bz2", "xz", "7z", "rar", "tgz"
    ]

    /// 排序用的稳定次序（目录已在排序时单独优先，这里排其余类型）。
    var sortRank: Int {
        switch self {
        case .directory: return 0
        case .image: return 1
        case .text: return 2
        case .code: return 3
        case .archive: return 4
        case .other: return 5
        }
    }
}

/// 批量操作类型。
enum BatchOperation: String {
    case move = "移动"
    case copy = "复制"
}

/// 批量传输的整体进度快照。
/// - total 为 0 时表示不确定进度（SSH 单命令回退场景）。
/// - totalBytes > 0 时进度条按字节渲染（单文件/大文件粘贴才有连续反馈）；否则按项数。
/// - transferredBytes 是当前文件已传字节，用于在文件名右侧显示 KB。
struct BatchProgress {
    let title: String
    let completed: Int
    let total: Int
    let detail: String
    let transferredBytes: Int64
    let totalBytes: Int64
}
