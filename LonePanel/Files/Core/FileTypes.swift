import Foundation

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
        let imageExts: Set<String> = [
            "jpg", "jpeg", "png", "gif", "heic", "heif", "bmp", "webp", "tiff", "tif", "ico"
        ]
        let codeExts: Set<String> = [
            "sh", "bash", "zsh", "py", "js", "ts", "jsx", "tsx", "swift", "c", "h", "cc",
            "cpp", "hpp", "java", "go", "rs", "rb", "php", "html", "htm", "css", "json",
            "yml", "yaml", "xml", "sql"
        ]
        let textExts: Set<String> = [
            "txt", "md", "markdown", "log", "toml", "ini", "conf", "cfg", "csv", "env"
        ]
        let archiveExts: Set<String> = [
            "zip", "tar", "gz", "bz2", "xz", "7z", "rar", "tgz"
        ]
        if imageExts.contains(ext) { self = .image }
        else if codeExts.contains(ext) { self = .code }
        else if textExts.contains(ext) { self = .text }
        else if archiveExts.contains(ext) { self = .archive }
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
