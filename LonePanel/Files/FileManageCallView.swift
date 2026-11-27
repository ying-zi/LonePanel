import SwiftUI

/// 文件「完整管理调用态」：供其它模块（如容器卷挂载点）经
/// ModuleCoordinator.manageFiles(at:title:) 唤起。
///
/// 与只读调用态 `FileCallView` 的区别：本视图复用入口态**完整的文件浏览器**
/// （`FileBrowserView`），天然具备新建/编辑/删除/上传/压缩/粘贴等全部操作，
/// 以及系统原生逐级返回——因为容器卷是宿主机上的真实目录，用户需要能操作文件。
///
/// 调用态隔离铁律依然严格遵守：
/// - 用独立 `FileBrowserModel` 实例（`@StateObject`），绝不触碰 shared；
/// - `isCallInstance = true`：禁止「设为默认目录」等写全局偏好的操作；
/// - 不注入设置入口（`@Environment(\.openSettings)` 在 sheet 中为空，齿轮自动隐藏）；
/// - 以 `callRootPath` 从指定目录（挂载点）作为导航栈底，看完下拉即走。
struct FileManageCallView: View {
    let target: ModuleCoordinator.FileOpenTarget

    @Environment(\.dismiss) private var dismiss
    /// 独立 model 实例：生命周期跟随本视图，关闭即释放。
    @StateObject private var model: FileBrowserModel

    init(target: ModuleCoordinator.FileOpenTarget) {
        self.target = target
        // 创建时就设好 callRootPath 与调用态标记，确保 FileBrowserView 的 .task 里
        // initializeNavigationIfNeeded() 读到的是挂载点而非默认目录（避免时序竞态）。
        let m = FileBrowserModel()
        m.isCallInstance = true
        m.callRootPath = target.path
        self._model = StateObject(wrappedValue: m)
    }

    var body: some View {
        // FileBrowserView 自带 NavigationStack（系统原生逐级返回），
        // 这里直接复用，通过 callClose 注入 sheet 关闭按钮，不再外嵌导航栈。
        // 连接与导航栈初始化交由 FileBrowserView 自己的 .task 完成（读取上面的 callRootPath）。
        FileBrowserView(model: model, callClose: { dismiss() })
            // 调用态同样跟随切服：连到新服务器后重置到新会话。
            .onReceive(AppEventBus.shared.serverChanges()) { _ in
                Task {
                    await model.reconnect()
                    model.resetNavigationToEntry()
                }
            }
    }
}
