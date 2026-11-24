import SwiftUI

/// 「再次点击当前 Tab」的一次命令，携带单调递增序号。
/// 序号是 Int 且只增不减，视图用 onChange 比较大小即可判断是否为新请求：
/// 旧方案用可选对象 + dropFirst，视图重建（切 Tab 时 iOS 26 会重建）会重新订阅，
/// dropFirst 跳过一次后就把真正的点击当成旧值忽略，或把旧值当新值消费，表现为横跳。
struct TabResetCommand: Equatable {
    let tabID: String
    let serial: Int
}

/// 根 Core 能力：Tab 重选导航中心。
/// App 层检测到用户再次点击当前已选中的 Tab 后，发一条带序号的命令；
/// 各模块按需监听、消费属于自己的命令，回到自己的根页面。
/// Core 只提供机制，不认识任何具体模块，删除模块时无需改动这里。
final class TabNavigationCenter: ObservableObject {
    static let shared = TabNavigationCenter()

    @Published private(set) var command = TabResetCommand(tabID: "", serial: 0)

    private var nextSerial = 0

    /// 单击当前 Tab：序号 +1 发出新命令。
    /// 不需要时间去重：iOS 26 单次点击可能连发，但命令携带递增序号，
    /// 且各模块消费端按「序号变大才响应 + 目标一致即幂等」处理，连发不会产生横跳。
    func requestReset(tabID: String) {
        nextSerial += 1
        command = TabResetCommand(tabID: tabID, serial: nextSerial)
    }
}
