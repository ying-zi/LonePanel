import SwiftUI

@main
struct LonePanelApp: App {
    init() {
        // 唯一集中调用各模块的启动钩子；App 层不认识任何具体模块实现。
        for module in TabRegistry.modules {
            module.configure()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
