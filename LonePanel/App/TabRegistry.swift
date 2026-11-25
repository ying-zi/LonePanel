import SwiftUI

// MARK: - 模块标识

/// 全部可插拔模块的稳定标识。新增插件模块时在此登记一个 id，并在 TabRegistry 加一行。
/// 注意：终端不是模块，而是 App 的底层能力（SSH），故不在这里——
/// 它恒可用，所有内容模块关闭时 App 直接进入全屏终端。
enum ModuleID: String, CaseIterable, Identifiable {
    case website
    case docker
    case database
    case files
    /// 设置是唯一的核心底座模块，不可关闭；用户进设置管理其它模块与连接。
    case settings

    var id: String { rawValue }

    /// 核心底座模块（设置页）不可关闭。
    var isCore: Bool { self == .settings }
}

// MARK: - 模块开关状态（持久化 + 可观察）

/// 模块开关的全局状态。底座能力（SSH / 终端 / 通知 / 日志）不在这里受开关影响。
/// 约束：设置页恒开不可关；内容模块允许全部关闭——此时 App 直接进入终端，是合法终态。
final class ModuleVisibility: ObservableObject {
    static let shared = ModuleVisibility()

    private let store = UserDefaults.standard
    private let keyPrefix = "com.lone.lonepanel.module.enabled."

    /// 当前启用的模块集合。
    @Published private(set) var enabled: Set<ModuleID> = []

    private init() {
        // 清理历史残留：终端曾作为"终端界面"开关存在于模块体系，现已移除该标识。
        store.removeObject(forKey: keyPrefix + "terminalUI")
        // 设置页恒开；内容模块读持久化状态，未设置过默认开启。
        // 全关是合法终态（进终端），不再强制兜底开 Docker。
        var set: Set<ModuleID> = [.settings]
        for id in ModuleID.allCases where !id.isCore {
            let key = keyPrefix + id.rawValue
            if store.object(forKey: key) == nil || store.bool(forKey: key) {
                set.insert(id)
            }
        }
        enabled = set
    }

    /// 启用的、占 Tab 的内容模块数量（不含设置页）。
    var enabledContentModuleCount: Int {
        enabled.subtracting([.settings]).count
    }

    /// 根视图形态。终端 UI 恒为底座、不参与判断，形态只由启用的内容模块数量决定。
    enum RootMode {
        case tabs                       // ≥2 个内容模块：正常 TabView
        case moduleFocus(TabModule)     // 恰好 1 个内容模块：全屏该模块
        case terminalFocus              // 0 个内容模块：全屏终端（底座兜底）
    }

    /// 当前根视图形态。
    var rootMode: RootMode {
        switch enabledContentModuleCount {
        case 0:
            return .terminalFocus
        case 1:
            if let module = singleModule { return .moduleFocus(module) }
            return .tabs
        default:
            return .tabs
        }
    }

    func isEnabled(_ id: ModuleID) -> Bool {
        enabled.contains(id)
    }

    /// 切换模块开关。返回是否成功（违反约束时返回 false 且不改变状态）。
    @discardableResult
    func set(_ id: ModuleID, enabled newValue: Bool) -> Bool {
        // 设置页是恒开底座，不可关闭。
        guard !id.isCore else { return false }
        // 内容模块允许全部关闭——此时 App 进入全屏终端，是合法终态，不再强制保留一个。

        if newValue {
            enabled.insert(id)
        } else {
            enabled.remove(id)
        }
        store.set(newValue, forKey: keyPrefix + id.rawValue)
        return true
    }

    /// 当前启用的、占 Tab 的模块（按注册表顺序）。
    /// 注意：这里会包含设置模块（核心，恒开），单模块模式下需单独处理。
    var enabledTabModules: [TabModule] {
        TabRegistry.modules.filter { module in
            guard let id = ModuleID(rawValue: module.id) else { return false }
            return isEnabled(id)
        }
    }

    /// 单模块模式下当前唯一的内容模块（排除设置）。
    var singleModule: TabModule? {
        enabledTabModules.first { $0.id != ModuleID.settings.rawValue }
    }
}

// MARK: - 模块注册表

/// Tab 注册表：整个 App 唯一登记具体模块的地方。
/// 删除任意模块时，只需删除该模块目录 + 删除下方对应一行，项目仍可编译。
enum TabRegistry {
    static let modules: [TabModule] = [
        WebsiteTab.module,
        DockerTab.module,
        DatabaseTab.module,
        FilesTab.module,
        SettingsTab.module,
    ]
}

// MARK: - 模块能力总线（跨模块调用的统一 API）

/// 模块间互调的唯一通道。任一模块只调用这里的方法，不直接引用别的模块视图/模型。
/// 设计原则（对齐"入口态 / 调用态"架构）：
/// - 关闭某模块的入口 ≠ 关闭它的能力：即便文件 Tab 被关，这里仍能调起文件浏览能力。
/// - 调用态"只干活"：以独立会话呈现、注入上下文参数（目标路径）、不读写用户偏好、
///   不污染单例导航栈；用户看完下拉即走，App 状态原地不动。
final class ModuleCoordinator: ObservableObject {
    static let shared = ModuleCoordinator()

    /// 一次跨模块文件浏览请求。Identifiable 便于 .sheet(item:) 呈现。
    struct FileOpenTarget: Identifiable {
        let id = UUID()
        /// 要打开的目录（服务器上绝对路径，如卷挂载的 Source）。
        let path: String
        /// 呈现标题（如容器名 + 挂载点）。
        let title: String
    }

    @Published var fileOpenTarget: FileOpenTarget?

    /// 统一 API：请求"文件模块"打开某个服务器目录（调用态）。
    /// - Parameters:
    ///   - path: 服务器绝对路径
    ///   - title: 调用态标题
    func openFiles(at path: String, title: String) {
        // 即便文件 Tab 未启用，能力仍可用——这里不检查 ModuleVisibility。
        fileOpenTarget = FileOpenTarget(path: path, title: title)
    }
}
