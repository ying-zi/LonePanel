import SwiftUI
import UIKit

/// 应用根视图：按模块开关决定根形态——多模块 Tab / 单模块全屏 / 纯终端全屏。
/// 采用 iOS 26 Liquid Glass 浮动标签栏。
struct ContentView: View {
    @ObservedObject private var visibility = ModuleVisibility.shared
    @ObservedObject private var coordinator = ModuleCoordinator.shared
    /// 语言切换后重建内容区，让所有 L10n.t() 立即重算；sheet 宿主身份保持不变。
    @ObservedObject private var localization = LocalizationStore.shared
    @AppStorage("com.lone.lonepanel.terminal.floating") private var floatingEnabled = true
    @State private var selection: String = ""
    @ObservedObject private var terminal = TerminalSession.shared
    @State private var showTerminal = false
    @State private var showSettings = false

    // 悬浮终端按钮可拖动定位（避开右下角删除/搜索等控件），位置持久化；松手吸附左右边缘。
    @AppStorage("com.lone.lonepanel.terminal.fab.offsetX") private var fabOffsetX: Double = 0
    @AppStorage("com.lone.lonepanel.terminal.fab.offsetY") private var fabOffsetY: Double = 0
    /// 拖动中的实时位移：纯内存态，绝不写 @AppStorage。
    /// 之前每帧写 AppStorage（UserDefaults 同步落盘 + 全视图重建）是拖动剧烈闪烁抖动的根因。
    @State private var fabLiveOffset: CGSize = .zero
    @State private var fabDragStart: CGSize = .zero
    @State private var isFabDragging = false

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

    /// FAB 实际渲染偏移：拖动中用内存态实时值，松手后用持久化值。
    private var fabRenderOffset: CGSize {
        isFabDragging ? fabLiveOffset : CGSize(width: fabOffsetX, height: fabOffsetY)
    }

    /// 悬浮终端底边距：多模块形态要避开底部 Tab 栏，单模块全屏没有 Tab 栏、贴底即可。
    private var fabBottomPadding: CGFloat {
        switch visibility.rootMode {
        case .tabs: return 90
        case .moduleFocus, .terminalFocus: return 28
        }
    }

    /// 主内容区。语言切换时仅此子树随 revision 重建，让所有 L10n.t() 立即重算；
    /// 外层的 ZStack 根容器（承载 sheet）身份保持不变。
    @ViewBuilder
    private var contentArea: some View {
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
        .id(localization.revision)
    }

    var body: some View {
        // 关键结构：稳定的 ZStack 根容器承载全部 sheet / overlay；
        // 会随语言换身份的 contentArea 作为它的子视图，.id(revision) 只作用于内层子树。
        // 切换语言时只有内容区重建，根容器（连着它的三个 .sheet）身份不变，
        // 正在显示的 sheet 不会被重新 present。
        ZStack {
            contentArea
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
        // 设置卡片：宿主固定为根视图，不随 rootMode 切换而重建。
        // 关键：终端兜底(0模块)下从设置里开启第一个模块时，rootMode 由 terminalFocus
        // 变为 moduleFocus，若 sheet 挂在 focusView 内部会随分支重建被重新 present，
        // 卡片 detents/圆角错乱。挂到根视图后宿主身份稳定，卡片始终是可下拉样式。
        .sheet(isPresented: $showSettings) {
            // 设置页自身不需要设置入口；清除注入，避免它 push 的终端也显示齿轮。
            SettingsView()
                .environment(\.openSettings, nil)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        // 跨模块调用态：文件能力由其它模块（如容器卷）经 ModuleCoordinator 唤起。
        // 呈现独立的调用态浏览器，不注入设置入口、不触碰单例导航栈与用户偏好。
        .sheet(item: $coordinator.fileOpenTarget) { target in
            FileCallView(target: target)
                .presentationDetents([.large])
        }
        .onAppear { ensureValidSelection() }
        .onChange(of: visibility.enabled) { oldValue, newValue in
            ensureValidSelection()
            let oldCount = oldValue.subtracting([.settings]).count
            let newCount = newValue.subtracting([.settings]).count
            // 从单模块/终端兜底（<2）开启到第二个模块（≥2）：根形态进入多模块 TabView，
            // 设置此时正是底部 Tab 之一。全屏 .large 卡片会盖住底部栏，让用户误以为
            // 「Tab 没弹出来」——这里主动收起卡片，立即露出包括设置 Tab 在内的底部栏。
            if oldCount < 2, newCount >= 2, showSettings {
                showSettings = false
            }
            // 关到 0 模块进终端兜底：终端自动聚焦输入框，卡片盖着会被键盘顶乱，主动收起。
            if newCount == 0, showSettings {
                showSettings = false
            }
        }
    }

    // MARK: - 多模块 Tab 视图

    private var tabView: some View {
        TabView(selection: $selection) {
            ForEach(visibleTabs) { module in
                module.view
                    .tabItem {
                        Label(L10n.t(module.title), systemImage: module.symbolName)
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
            // 设置 sheet 不挂在这里：本视图随 rootMode 切换被整体重建，挂这里会让卡片重新 present 而错乱；
            // sheet 已上移到 body 根视图，宿主身份稳定。
            .environment(\.openSettings, openSettingsAction)
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
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // 位移超过阈值才算拖动；小于阈值交给 onEnded 当点击处理。
                        let moved = hypot(value.translation.width, value.translation.height)
                        if !isFabDragging && moved > 6 {
                            isFabDragging = true
                            // 以当前持久位置为基准，避免每次手势都从旧值跳变。
                            fabDragStart = CGSize(width: fabOffsetX, height: fabOffsetY)
                        }
                        if isFabDragging {
                            let x = Double(fabDragStart.width) + value.translation.width
                            let y = Double(fabDragStart.height) + value.translation.height
                            // 只更新内存态：不落盘、不触发 AppStorage 写入，跟手零延迟。
                            fabLiveOffset = CGSize(width: clamp(fabX: x), height: clamp(fabY: y))
                        }
                    }
                    .onEnded { _ in
                        if !isFabDragging {
                            // 没有实质位移 → 视为点击，打开终端。
                            showTerminal = true
                            return
                        }
                        let finalX = Double(fabLiveOffset.width)
                        let finalY = Double(fabLiveOffset.height)
                        // 松手一次性写入持久化位置：越过屏幕中线贴左，否则贴右。
                        let snappedX = finalX < fabMidX ? fabMinX : 0
                        withAnimation(.spring(response: 0.3)) {
                            fabOffsetX = snappedX
                            fabOffsetY = clamp(fabY: finalY)
                            // 结束拖动，渲染源切回持久位置；spring 让吸附平滑，不再逐帧重建。
                            isFabDragging = false
                        }
                        fabLiveOffset = .zero
                        fabDragStart = CGSize(width: snappedX, height: clamp(fabY: finalY))
                    }
            )
            .offset(x: fabRenderOffset.width, y: fabRenderOffset.height)
            .padding(.trailing, 20)
            .padding(.bottom, fabBottomPadding)
            .accessibilityLabel(L10n.t("Open terminal; long press to drag its position"))
            .transition(.scale.combined(with: .opacity))
            // 注意：这两个 animation 不能挂到 offset 上。拖动中 offset 由 fabRenderOffset 驱动，
            // 若带动画会逐帧追赶造成抖动；动画只在出现/隐藏与状态色变化时使用。
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
