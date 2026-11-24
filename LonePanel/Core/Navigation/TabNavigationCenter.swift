import SwiftUI

/// 一次「再次点击当前 Tab」的请求。携带 Tab id 与唯一序号，
/// 保证连续点同一个 Tab 时 onChange 也能捕获到变化。
struct TabResetRequest: Equatable {
    let tabID: String
    let nonce: UUID
}

/// 根 Core 能力：Tab 重选导航中心。
/// App 层检测到用户再次点击当前已选中的 Tab 后，广播一次重置请求；
/// 各模块视图按需监听并把属于自己 id 的请求消费掉，回到自己的根页面。
/// Core 只提供机制，不认识任何具体模块，删除模块时无需改动这里。
final class TabNavigationCenter: ObservableObject {
    static let shared = TabNavigationCenter()

    @Published var resetRequest: TabResetRequest?

    /// 去重：iOS 26 TabView 的 selection binding setter 在单击时可能连续触发多次，
    /// 若不拦截会对同一 Tab 连发多次重置，导致文件页导航栈反复 pop/push「横跳」。
    private var lastTabID: String?
    private var lastRequestTime: Date?

    func requestReset(tabID: String) {
        let now = Date()
        if let lastTabID, lastTabID == tabID,
           let lastRequestTime, now.timeIntervalSince(lastRequestTime) < 0.4 {
            return
        }
        lastTabID = tabID
        lastRequestTime = now
        resetRequest = TabResetRequest(tabID: tabID, nonce: UUID())
    }
}
