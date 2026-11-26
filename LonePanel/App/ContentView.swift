import SwiftUI
import UIKit

/// 应用根视图：按模块开关决定根形态——多模块 Tab / 单模块全屏 / 纯终端全屏。
/// 采用 iOS 26 Liquid Glass 浮动标签栏。
struct ContentView: View {
    @ObservedObject private var visibility = ModuleVisibility.shared
    @ObservedObject private var coordinator = ModuleCoordinator.shared
    @AppStorage("com.lone.lonepanel.terminal.floating") private var floatingEnabled = true
    @State private var selection: String = ""
    @ObservedObject private var terminal = TerminalSession.shared
    @State private var showTerminal = false
    @State private var showSettings = false

    // 悬浮终端按钮可拖动定位（避开右下角删除/搜索等控件），位置持久化；松手吸附左右边缘。
    @AppStorage("com.lone.lonepanel.terminal.fab.offsetX") private var fabOffsetX: Double = 0
    @AppStorage("com.lone.lonepanel.terminal.fab.offsetY") private var fabOffsetY: Double = 0
    @State private var fabDragStart: CGSize = .zero

    /// 当前可见的 Tab 模块（多模块形态下使用）。
    private var visibleTabs: [TabModule] {
        visibility.enabledTabModules
    }

    /// 当前形态下是否显示悬浮终端按钮。按根形态分别判定：
    /// - 多模块：取当前选中 Tab 的配置；
    /// - 单模块全屏：直接用 rootMode 携带的模块——此形态下 TabView 未渲染，
    ///   selection 可能是旧值/空值，绝不能依赖它；
    /// - 纯终端全屏：本身就是终端，无需悬浮入口。
    private var currentModuleShowsTerminal: Bool {
        switch visibility.rootMode {
        case .tabs:
            guard let module = visibleTabs.first(where: { $0.id == selection }) else { return false }
            return module.showsFloatingTerminal
        case .moduleFocus(let module):
            return module.showsFloatingTerminal
        case .terminalFocus:
            return false
        }
    }

    /// 悬浮终端按钮颜色：蓝=已连接，红=已断开，橙=连接中/自动重连。
    private var terminalStatusColor: Color {
        if terminal.userDisconnected { return .red }
        if terminal.isReady { return .accentColor }
        return .orange
    }

    /// 悬浮终端底边距：多模块形态要避开底部 Tab 栏，单模块全屏没有 Tab 栏、贴底即可。
    private var fabBottomPadding: CGFloat {
        switch visibility.rootMode {
        case .tabs: return 90
        case .moduleFocus, .terminalFocus: return 28
        }
    }

    var body: some View {
        Group {
            switch visibility.rootMode {
            case .tabs:
                tabView
            case .moduleFocus(let module):
                focusView { module.view }
            case .terminalFocus:
                focusView {
                    TerminalView(presentation: .pushed)
                }
            }
        }
        // 悬浮终端入口：开关开启 + 当前形态宿主模块允许时出现。
        // 单模块全屏（moduleFocus）里容器/网站/数据库同样要有悬浮终端——只留一个模块
        // 恰恰是最需要终端兜底的场景；纯终端形态（terminalFocus）本身就是终端，自动隐藏。
        .overlay(alignment: .bottomTrailing) {
            if floatingEnabled && currentModuleShowsTerminal {
                terminalFab
            }
        }
        .sheet(isPresented: $showTerminal) {
            TerminalView()
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .interactiveDismissDisabled(true)
        }
        // 跨模块调用态：文件能力由其它模块（如容器卷）经 ModuleCoordinator 唤起。
        // 呈现独立的调用态浏览器，不注入设置入口、不触碰单例导航栈与用户偏好。
        .sheet(item: $coordinator.fileOpenTarget) { target in
            FileCallView(target: target)
                .presentationDetents([.large])
        }
        .onAppear { ensureValidSelection() }
        .onChange(of: visibility.enabled) { _, _ in ensureValidSelection() }
    }

    // MARK: - 多模块 Tab 视图

    private var tabView: some View {
        TabView(selection: $selection) {
            ForEach(visibleTabs) { module in
                module.view
                    .tabItem {
                        Label(module.title, systemImage: module.symbolName)
                    }
                    .tag(module.id)
            }
        }
    }

    // MARK: - 全屏聚焦视图（单模块 / 纯终端）

    @ViewBuilder
    private func focusView<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            // 入口态：注入设置动作，模块会把齿轮放进「自己的」导航栏 trailing。
            // 调用态不经过这里，openSettings 为 nil，齿轮自动隐藏——只干活、不暴露入口。
            .environment(\.openSettings, openSettingsAction)
            .sheet(isPresented: $showSettings) {
                // 设置页自身不需要设置入口；清除注入，避免它 push 的终端也显示齿轮。
                SettingsView()
                    .environment(\.openSettings, nil)
            }
    }

    /// 入口态注入的设置动作：捕获的是 @State 存储，视图重建后仍指向同一状态。
    private var openSettingsAction: () -> Void {
        { showSettings = true }
    }

    // MARK: - 悬浮终端按钮

    private var terminalFab: some View {
        Image(systemName: "terminal")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 56, height: 56)
            .background(terminalStatusColor, in: Circle())
            .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 3)
            .overlay {
                // 右下角小角标：提示「可拖动」，避免用户不知道能挪走避开遮挡。
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .offset(x: 18, y: -18)
            }
            .contentShape(Circle())
            .onTapGesture { showTerminal = true }
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { value in
                        let x = Double(fabDragStart.width) + value.translation.width
                        let y = Double(fabDragStart.height) + value.translation.height
                        fabOffsetX = clamp(fabX: x)
                        fabOffsetY = clamp(fabY: y)
                    }
                    .onEnded { _ in
                        // 松手吸附：越过屏幕中线则贴左，否则贴右；纵向钳制在安全区。
                        withAnimation(.spring(response: 0.3)) {
                            fabOffsetX = fabOffsetX < fabMidX ? fabMinX : 0
                            fabOffsetY = clamp(fabY: fabOffsetY)
                        }
                        fabDragStart = CGSize(width: fabOffsetX, height: fabOffsetY)
                    }
            )
            .offset(x: fabOffsetX, y: fabOffsetY)
            .padding(.trailing, 20)
            .padding(.bottom, fabBottomPadding)
            .onAppear { fabDragStart = CGSize(width: fabOffsetX, height: fabOffsetY) }
            .accessibilityLabel("打开终端，长按可拖动位置")
            .transition(.scale.combined(with: .opacity))
            .animation(.spring(response: 0.3), value: currentModuleShowsTerminal)
            .animation(.easeInOut, value: terminalStatusColor)
    }

    /// FAB 拖动边界：X 从贴右(0)到贴左(fabMinX)，中线用于吸附判定。
    private var fabMinX: Double {
        -Double(max(0, UIScreen.main.bounds.width - 56 - 40))
    }

    private var fabMidX: Double { fabMinX / 2 }

    private func clamp(fabX: Double) -> Double {
        min(0, max(fabMinX, fabX))
    }

    private func clamp(fabY: Double) -> Double {
        // 向上最多到导航栏下方，向下不越过原始位置太多。
        let upLimit = -Double(UIScreen.main.bounds.height) * 0.6
        return min(120, max(upLimit, fabY))
    }

    /// 开关变化后，若当前 selection 已不在可见 Tab 中，切到第一个可见模块。
    private func ensureValidSelection() {
        let ids = visibleTabs.map(\.id)
        if ids.contains(selection) { return }
        selection = ids.first ?? ""
    }
}
