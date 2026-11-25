import SwiftUI
import UIKit
import SwiftTerm

/// 终端的呈现方式，决定右上角辅助按钮的语义。
/// 全形态统一：右上角恒定一个「重新连接」圆形箭头；此处只决定附带按钮。
enum TerminalPresentation {
    case sheet   // 悬浮按钮弹出：附带「收起」
    case pushed  // 推入（仅终端全屏 / 设置页）：入口态附带「设置」，否则无
}

/// 终端主题色：Ctrl 锁定、按压反馈统一使用同一蓝。
private enum TerminalTheme {
    static let lockBlue = Color(red: 0.16, green: 0.48, blue: 0.96)
}

/// 快捷键栏共享状态：SwiftUI 按钮与 SwiftTerm delegate 都读写它。
final class TerminalKeyState: ObservableObject {
    @Published var ctrlLocked = false
    /// SwiftTerm 视图引用，用于本地清屏 / 键盘收展。由 Coordinator 设置。
    weak var terminalView: SwiftTerm.TerminalView?

    func toggleCtrl() {
        ctrlLocked.toggle()
    }

    func unlockCtrl() {
        ctrlLocked = false
    }

    func clearScreen() {
        // ED(2) 清屏 + 光标归位，交给 SwiftTerm 本地解释，不影响远端。
        terminalView?.feed(byteArray: Array("\u{1B}[2J\u{1B}[H".utf8)[...])
    }
}

/// 默认用系统英文键盘的 SwiftTerm 终端视图。
/// 终端里敲命令/路径都是 ASCII，中文输入法容易带出候选栏、误输入标点；
/// 通过覆写 UIResponder 的 textInputMode 指定英文键盘（官方支持，非私有 API）。
/// 前提：用户已在系统设置中添加英文键盘；未添加则回退系统默认，不影响使用。
private final class EnglishKeyboardTerminalView: SwiftTerm.TerminalView {
    override var textInputMode: UITextInputMode? {
        for mode in UITextInputMode.activeInputModes {
            if let lang = mode.primaryLanguage, lang.hasPrefix("en") {
                return mode
            }
        }
        return super.textInputMode
    }
}

/// SwiftTerm 官方 TerminalView 的 SwiftUI 包装。
private struct TerminalHostView: UIViewRepresentable {
    let session: TerminalSession
    let keyState: TerminalKeyState
    let focusTick: Int
    let fontSize: Double

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let view = EnglishKeyboardTerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        // 禁用 SwiftTerm 自带键盘工具条，改用我们自己的快捷键栏。
        view.inputAccessoryView = nil
        // 关闭弹性回弹：终端回滚到顶/到底后继续下拉时，不再把滚动手势传给外层 sheet
        // 触发下拉关闭；拖顶部把手关闭走 sheet 自己的手势，不受影响。
        view.bounces = false
        view.alwaysBounceVertical = false
        view.font = UIFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        keyState.terminalView = view

        // 服务器字节 → SwiftTerm 仿真器。注册一次：只登记 handler，等布局完成后 markReady 回放。
        session.byteBridge.register { [weak view] bytes in
            guard let view else { return }
            if Thread.isMainThread {
                view.feed(byteArray: bytes[...])
            } else {
                DispatchQueue.main.async { view.feed(byteArray: bytes[...]) }
            }
        }
        // 稍延迟：等视图上 window、布局完成（列数确定）后回放历史 + 聚焦。
        // sizeChanged 会优先做这件事；这里作为兜底，覆盖「重建后列数未变、回调不来」的情况。
        // 宽度门槛：view 首次出现可能在动画中间态（极窄），此时回放会把历史挤成窄列。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if view.bounds.width >= 200 { context.coordinator.initializeIfNeeded(view) }
            view.becomeFirstResponder()
        }
        return view
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {
        // 字号变化只更新字体，绝不重建视图：SwiftTerm 的 font setter 内部会
        // resetFont() 重算单元格并 resize 重排历史；重建会丢失 first responder，
        // 导致键盘闪烁，并打断正在进行的 Slider 拖拽手势（只能一格一格跳）。
        if context.coordinator.currentFontSize != fontSize {
            context.coordinator.currentFontSize = fontSize
            uiView.font = UIFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
            // font setter 内部 resetFont 会清屏，同步重喂缓存字节按新列宽重建画面，历史不丢。
            // 必须同步：异步排队会在连续拖动时多次回放导致历史重复；font setter 返回时清屏已完成。
            session.byteBridge.replay()
        }
        if focusTick > 0 {
            DispatchQueue.main.async { uiView.becomeFirstResponder() }
        }
    }

    static func dismantleUIView(_ uiView: SwiftTerm.TerminalView, coordinator: Coordinator) {
        uiView.terminalDelegate = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, keyState: keyState, fontSize: fontSize)
    }

    final class Coordinator: TerminalViewDelegate {
        let session: TerminalSession
        let keyState: TerminalKeyState
        /// 当前已应用到 SwiftTerm 的字号，用于 updateUIView 检测变化后原地更新字体。
        var currentFontSize: Double
        /// 布局完成回调是否已处理（回放历史），只做一次。
        private var didInitialize = false

        init(session: TerminalSession, keyState: TerminalKeyState, fontSize: Double) {
            self.session = session
            self.keyState = keyState
            self.currentFontSize = fontSize
        }

        /// 键盘/快捷键产生的字节发往远端。Ctrl 锁定时把字母转成对应控制字符。
        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            let bytes: [UInt8] = data.map { byte in
                if keyState.ctrlLocked {
                    if byte >= 0x61 && byte <= 0x7A { return byte - 0x60 } // a-z -> 0x01...
                    if byte >= 0x41 && byte <= 0x5A { return byte - 0x40 } // A-Z -> 0x01...
                }
                return byte
            }
            MainActor.assumeIsolated { session.send(bytes) }
        }

        /// 视图列数确定后做一次初始化：回放历史。幂等。
        func initializeIfNeeded(_ view: SwiftTerm.TerminalView) {
            MainActor.assumeIsolated {
                guard !didInitialize else { return }
                didInitialize = true
                keyState.terminalView = view
                session.byteBridge.markReady()
            }
        }

        /// SwiftTerm 布局后回调实际列行。首次回调时视图列数已确定——此刻才回放历史字节，
        /// 避免「按默认 80 列排版后再改列数」导致文字被裁半截。
        /// 列数门槛：动画中间态会回调极小列数（如 6），此时回放会把历史挤成窄条，故等到合理列数再回放。
        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            if newCols >= 20 { initializeIfNeeded(source) }
            MainActor.assumeIsolated { session.resize(columns: newCols, rows: newRows) }
        }

        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {}
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}

/// 内置 SSH 终端界面：上方为 SwiftTerm 完整终端，下方为混合 Ctrl 快捷键栏。
struct TerminalView: View {
    var presentation: TerminalPresentation = .sheet
    /// 导航栏标题：系统终端为「SSH 终端」，容器终端传容器名。
    var title: String = "SSH 终端"

    @ObservedObject private var session: TerminalSession
    @StateObject private var keyState = TerminalKeyState()
    @Environment(\.dismiss) private var dismiss
    /// 有注入 = 入口态全屏终端（给设置入口）；无注入 = 设置页 push 的终端（给断开管理）。
    @Environment(\.openSettings) private var openSettings
    @State private var focusTick = 0
    /// 字号面板是否内联展开（不再用模态弹窗，避免遮挡键盘）。
    @State private var showFontPanel = false
    @AppStorage("com.lone.lonepanel.terminal.fontSize") private var fontSize = 14.0
    @State private var keyboardShown = true

    /// 默认仍用系统终端单例——ContentView / SettingsView 的现有调用不受影响。
    /// Docker 容器终端注入独立 exec 会话 + 容器名标题。
    init(session: TerminalSession = .shared, presentation: TerminalPresentation = .sheet, title: String = "SSH 终端") {
        self._session = ObservedObject(wrappedValue: session)
        self.presentation = presentation
        self.title = title
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                terminalArea
                shortcutBar
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardShown = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardShown = false
            }
            // 用户打开终端即视为主动唤起：解除断开标记并连接（幂等）。
            .task { await session.activateForUser() }
            .onChange(of: session.isReady) { _, ready in
                if ready { focusTick += 1 }
            }
            .onAppear {
                if session.isReady { focusTick += 1 }
            }
        }
    }

    // MARK: - 顶部栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showFontPanel.toggle() }
            } label: {
                // 自定义 Aa 文字：iOS 26 下 SF Symbol textformat.size 会被渲染成"大小"等本地化名，
                // 用确定的文字避免显示被系统改写。
                Text("Aa")
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                    .foregroundStyle(showFontPanel ? TerminalTheme.lockBlue : Color.primary)
            }
            .help("字号设置")
            .accessibilityLabel(showFontPanel ? "收起字号设置" : "字号设置")
        }
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 14) {
                // 全形态统一：右上角恒定一个「重新连接」圆形箭头。
                // SSH 是整个 App 的生命线，断开会导致全局失效，故不再把「断开/连接」
                // 做成终端随手操作；连接状态由设置页统一管理，这里只提供"重连自救"。
                Button {
                    Task { await session.reconnect() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("重新连接")
                .accessibilityLabel("重新连接")
                .disabled(session.isConnecting)

                switch presentation {
                case .sheet:
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .accessibilityLabel("收起终端")
                case .pushed:
                    // 全形态唯一的区别：入口态（仅终端模块全屏）才显示设置齿轮——
                    // 它是用户进设置把其它模块开回来的唯一通道；设置页 push 的终端无注入，自动隐藏。
                    if openSettings != nil {
                        SettingsGearButton()
                    }
                }
            }
        }
    }

    // MARK: - 终端显示区

    /// SwiftTerm 终端视图 + 连接状态覆盖层。
    /// 字号变化通过 updateUIView 原地更新字体（SwiftTerm 内部 resetFont 重排），
    /// 不用 id 重建视图——重建会丢焦点导致键盘闪烁、打断滑块拖拽手势。
    private var terminalArea: some View {
        TerminalHostView(
            session: session,
            keyState: keyState,
            focusTick: focusTick,
            fontSize: fontSize
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if session.isConnecting && !session.isReady {
                ProgressView("正在连接…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else if let error = session.errorMessage, !session.isReady {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("重试") { Task { await session.activateForUser() } }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
            }
        }
        .overlay(alignment: .top) {
            if let notice = session.notice {
                Text(notice)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        // 点击面板以外的终端区域时收起字号面板。放在面板 overlay 之下，
        // 确保先命中面板（滑块可拖）；面板收起后本层消失，终端交互不受影响。
        .overlay {
            if showFontPanel {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) { showFontPanel = false }
                    }
            }
        }
        // 内联字号面板：悬浮在终端顶部，不弹模态窗，键盘在底部互不遮挡。
        .overlay(alignment: .topLeading) {
            if showFontPanel { fontPanel }
        }
        .animation(.easeInOut, value: session.notice)
    }

    /// 内联展开的字号滑块条：一行「字号 [滑块] Npt」，宽 300pt，磨砂背景。
    private var fontPanel: some View {
        HStack(spacing: 10) {
            Text("字号")
                .font(.system(size: 14, weight: .medium))
            Slider(value: $fontSize, in: 12...18, step: 1)
                .tint(TerminalTheme.lockBlue)
            Text("\(Int(fontSize))pt")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
        .padding(.leading, 12)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - 快捷键栏

    /// 常驻一排 + Ctrl 锁定时展开的一排。所有按键限宽、按压变色 + 触感反馈。
    private var shortcutBar: some View {
        VStack(spacing: 8) {
            if keyState.ctrlLocked {
                // 展开行：只留最高频的三个，完整文字「Ctrl + X」撑宽。
                // 第三项由原 Ctrl+D 改为 Ctrl+L 清屏（垃圾桶已从右上角移除，清屏收在这里）。
                HStack(spacing: 8) {
                    comboKey("Ctrl + C", byte: 0x03)
                    comboKey("Ctrl + Z", byte: 0x1A)
                    comboKey("Ctrl + L", byte: 0x0C)
                }
                .frame(maxWidth: 460)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // 常驻行：CTRL 在最左，键盘收展在最右。
            HStack(spacing: 8) {
                ctrlKey()
                controlKey("Tab", bytes: [0x09])
                controlKey("Esc", bytes: [0x1B])
                arrowKey("↑", sequence: [0x1B, 0x5B, 0x41])
                arrowKey("↓", sequence: [0x1B, 0x5B, 0x42])
                Spacer(minLength: 4)
                keyboardToggleKey()
            }
            .frame(maxWidth: 460)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .top) { Divider() }
        .animation(.easeInOut(duration: 0.18), value: keyState.ctrlLocked)
    }

    /// 左一：CTRL 键，字母标识，点亮变蓝。
    private func ctrlKey() -> some View {
        Button {
            haptic()
            keyState.toggleCtrl()
        } label: {
            Text("CTRL")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .frame(width: 60, height: 44)
                .foregroundStyle(keyState.ctrlLocked ? .white : .primary)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(keyState.ctrlLocked ? TerminalTheme.lockBlue : Color(uiColor: .secondarySystemBackground))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(keyState.ctrlLocked ? "关闭 Ctrl 锁定" : "开启 Ctrl 锁定")
    }

    private func controlKey(_ title: String, bytes: [UInt8]) -> some View {
        Button {
            haptic()
            session.send(bytes)
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: 62, minHeight: 44)
                .foregroundStyle(.primary)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!session.isReady)
    }

    private func arrowKey(_ title: String, sequence: [UInt8]) -> some View {
        controlKey(title, bytes: sequence)
    }

    /// 展开行组合键：完整文字、撑宽、按压反馈。
    private func comboKey(_ title: String, byte: UInt8) -> some View {
        Button {
            haptic()
            session.send([byte])
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(TerminalTheme.lockBlue)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(TerminalTheme.lockBlue.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .disabled(!session.isReady)
    }

    /// 右一：键盘收展，正方形，与 CTRL 同高。
    private func keyboardToggleKey() -> some View {
        Button {
            haptic()
            if keyboardShown {
                keyState.terminalView?.resignFirstResponder()
            } else {
                keyState.terminalView?.becomeFirstResponder()
            }
        } label: {
            Image(systemName: keyboardShown ? "chevron.down" : "chevron.up")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .foregroundStyle(TerminalTheme.lockBlue)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(TerminalTheme.lockBlue.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(keyboardShown ? "收起键盘" : "展开键盘")
    }

    private func haptic() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
