import SwiftUI

@main
struct LonePanelApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 唯一集中调用各模块的启动钩子；App 层不认识任何具体模块实现。
        for module in TabRegistry.modules {
            module.configure()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // 冷启动：App 进入前台后确保终端连接（用户主动断开过则跳过）。
                .task {
                    await TerminalSession.shared.ensureAlive()
                }
                // 从后台切回前台：立即检查连接状态并按需重连。
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await TerminalSession.shared.ensureAlive() }
                }
        }
    }
}
