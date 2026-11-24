import SwiftUI

/// 应用根视图：遍历注册表装配 Tab，不硬编码任何具体模块视图。
/// 采用 iOS 26 Liquid Glass 浮动标签栏。
struct ContentView: View {
    @State private var selection: String = TabRegistry.modules.first?.id ?? ""
    @AppStorage("com.lone.lonepanel.terminal.floating") private var floatingEnabled = true
    @State private var showTerminal = false
    @ObservedObject private var terminal = TerminalSession.shared

    /// 当前选中的模块是否显示悬浮终端按钮。
    private var currentModuleShowsTerminal: Bool {
        TabRegistry.modules.first { $0.id == selection }?.showsFloatingTerminal ?? false
    }

    /// 悬浮终端按钮颜色：蓝=已连接，红=已断开，橙=连接中/自动重连。
    private var terminalStatusColor: Color {
        if terminal.userDisconnected { return .red }
        if terminal.isReady { return .accentColor }
        return .orange // 连接中或断线重连中
    }

    /// 用普通 $selection，不再拦截「再次点击当前 Tab」。
    /// 文件模块把导航栈底设为默认目录后，iOS 26 点当前 Tab 系统级 pop 到栈底，
    /// 落点天然就是默认目录，无需任何自定义 binding 拦截。
    var body: some View {
        TabView(selection: $selection) {
            ForEach(TabRegistry.modules) { module in
                module.view
                    .tabItem {
                        Label(module.title, systemImage: module.symbolName)
                    }
                    .tag(module.id)
            }
        }
        // 底部 TabBar 常显：不随列表滚动收起，五个 Tab 始终可见。
        .overlay(alignment: .bottomTrailing) {
            if floatingEnabled && currentModuleShowsTerminal {
                Button {
                    showTerminal = true
                } label: {
                    Image(systemName: "terminal")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(terminalStatusColor, in: Circle())
                        .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 3)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 20)
                // 抬到底部 TabBar 之上，避免被遮挡或点击穿透到列表。
                .padding(.bottom, 90)
                .accessibilityLabel("打开终端")
                .transition(.scale.combined(with: .opacity))
                .animation(.spring(response: 0.3), value: currentModuleShowsTerminal)
                .animation(.easeInOut, value: terminalStatusColor)
            }
        }
        .sheet(isPresented: $showTerminal) {
            TerminalView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}
