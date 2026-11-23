import SwiftUI

/// 顶级 Tab 的标识与展示信息。
/// 只描述数据，不引用任何功能模块，保证全局层不反向依赖模块。
enum AppTab: Hashable {
    case website
    case docker
    case database
    case files
    case settings

    var title: String {
        switch self {
        case .website: return "网站"
        case .docker: return "Docker"
        case .database: return "数据库"
        case .files: return "文件"
        case .settings: return "设置"
        }
    }

    var symbolName: String {
        switch self {
        case .website: return "globe"
        case .docker: return "shippingbox"
        case .database: return "cylinder.split.1x2"
        case .files: return "folder"
        case .settings: return "gearshape"
        }
    }
}
