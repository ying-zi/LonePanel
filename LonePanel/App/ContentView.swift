import SwiftUI

/// 应用根视图：按模块开关决定根形态——多模块 Tab / 单模块全屏 / 纯终端全屏。
/// 采用 iOS 26 Liquid Glass 浮动标签栏。
struct ContentView: View {
    @ObservedObject private var visibility = ModuleVisibility.shared
    @AppStorage("com.lone.lonepanel.terminal.floating") private var floatingEnabled = true
    @State private var selection: String = ""
    @ObservedObject private var terminal = TerminalSession.shared
    @State private var showTerminal = false
    @State private var showSettings = false

    /// 当前可见的 Tab 模块（多模块形态下使用）。
    private var visibleTabs: [TabModule] {
        visibility.enabledTabModules
    }

    /// 当前选中的模块是否显示悬浮终端按钮。
    private var currentModuleShowsTerminal: Bool {
        guard let module = visibleTabs.first(where: { $0.id == selection }) else { return false }
        return module.showsFloatingTerminal
    }

    /// 悬浮终端按钮颜色：蓝=已连接，红=已断开，橙=连接中/自动重连。
    private var terminalStatusColor: Color {
        if terminal.userDisconnected { return .red }
        if terminal.isReady { return .accentColor }
        return .orange
    }

    /// 是否处于全屏聚焦形态（单模块 / 纯终端）——此时不显示悬浮终端按钮。
    private var isFocused: Bool {
        switch visibility.rootMode {
        case .moduleFocus, .terminalFocus: return true
        case .tabs: return false
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
        // 悬浮终端入口：仅多模块形态、终端 UI 模块启用、当前模块允许时出现。
        .overlay(alignment: .bottomTrailing) {
            if visibility.terminalUIEnabled && floatingEnabled && !isFocused
                && currentModuleShowsTerminal {
                terminalFab
            }
        }
        .sheet(isPresented: $showTerminal) {
            TerminalView()
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .interactiveDismissDisabled(true)
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
            .safeAreaInset(edge: .top) {
                // 顶部细条放设置入口：用户靠它进设置把其它模块开回来。
                HStack {
                    Spacer()
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("设置")
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
    }

    // MARK: - 悬浮终端按钮

    private var terminalFab: some View {
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
        .padding(.bottom, 90)
        .accessibilityLabel("打开终端")
        .transition(.scale.combined(with: .opacity))
        .animation(.spring(response: 0.3), value: currentModuleShowsTerminal)
        .animation(.easeInOut, value: terminalStatusColor)
    }

    /// 开关变化后，若当前 selection 已不在可见 Tab 中，切到第一个可见模块。
    private func ensureValidSelection() {
        let ids = visibleTabs.map(\.id)
        if ids.contains(selection) { return }
        selection = ids.first ?? ""
    }
}
