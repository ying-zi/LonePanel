import SwiftUI
import UIKit
import SwiftTerm

/// 终端的呈现方式，决定右上角操作按钮的语义。
enum TerminalPresentation {
    case sheet   // 悬浮按钮弹出：右上角为「收起」
    case pushed  // 设置页推入：右上角为「断开 / 连接」
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

    /// 把自动换行偏好应用到本地仿真器（DECAWM：?7h 开 / ?7l 关）。
    func applyAutoWrap(_ enabled: Bool) {
        let seq = enabled ? "\u{1B}[?7h" : "\u{1B}[?7l"
        terminalView?.feed(byteArray: Array(seq.utf8)[...])
    }
}

/// 宽列模式的外层容器：只负责横向滚动，纵向滚动交给内层 TerminalView（scrollback）。
private final class HorizontalTerminalScrollView: UIScrollView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isDirectionalLockEnabled = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = true
        bounces = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// SwiftTerm 官方 TerminalView 的 SwiftUI 包装。
private struct TerminalHostView: UIViewRepresentable {
    let session: TerminalSession
    let keyState: TerminalKeyState
    let focusTick: Int
    let fontSize: Double
    let autoWrap: Bool
    /// > 0 时启用宽列横滚：视图物理宽度 = 虚拟列数 × 字符宽，外层横向 UIScrollView 承载。
    let virtualColumns: Int

    /// 与 SwiftTerm computeFontDimensions 保持一致：等宽字体下 "W" 的 advance 即单列宽。
    private static func cellWidth(for fontSize: Double) -> CGFloat {
        let font = UIFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        return max(1, "W".size(withAttributes: [.font: font]).width)
    }

    func makeUIView(context: Context) -> UIView {
        let view = SwiftTerm.TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        // 禁用 SwiftTerm 自带键盘工具条，改用我们自己的快捷键栏。
        view.inputAccessoryView = nil
        view.font = UIFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        keyState.terminalView = view

        // 服务器字节 → SwiftTerm 仿真器。注册一次：只登记 handler，等布局完成后 markReady 回放。
        // 每次喂入后做光标跟随（仅宽列模式生效），保证输入/回显时光标始终在可见窗口内。
        let coordinator = context.coordinator
        session.byteBridge.register { [weak view] bytes in
            guard let view else { return }
            let feed = {
                view.feed(byteArray: bytes[...])
                coordinator.followCursor(in: view)
            }
            if Thread.isMainThread {
                feed()
            } else {
                DispatchQueue.main.async(execute: feed)
            }
        }

        let container: UIView
        if virtualColumns > 0 {
            // 宽列模式：固定内层视图宽度为虚拟列宽，外层横向滚动承载。
            let scroller = HorizontalTerminalScrollView()
            scroller.delegate = context.coordinator
            scroller.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            // +2pt 余量：确保 Int(width / cellWidth) 精确得到 virtualColumns 而非少一列。
            let width = Self.cellWidth(for: fontSize) * CGFloat(virtualColumns) + 2
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor),
                view.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
                view.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
                view.widthAnchor.constraint(equalToConstant: width),
                view.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor),
            ])
            coordinator.hostScrollView = scroller
            container = scroller
        } else {
            // 窄屏模式：宽度交给 SwiftUI = 可见宽度，行为与之前一致。
            view.translatesAutoresizingMaskIntoConstraints = false
            container = view
        }

        // 稍延迟：等视图上 window、布局完成（列数确定）后，应用换行偏好 + 回放历史 + 聚焦。
        // sizeChanged 会优先做这件事；这里作为兜底，覆盖「重建后列数未变、回调不来」的情况。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            coordinator.initializeIfNeeded(view)
            view.becomeFirstResponder()
        }
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if focusTick > 0 {
            DispatchQueue.main.async { context.coordinator.terminalView?.becomeFirstResponder() }
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.terminalView?.terminalDelegate = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, keyState: keyState, autoWrap: autoWrap)
    }

    final class Coordinator: NSObject, TerminalViewDelegate, UIScrollViewDelegate {
        let session: TerminalSession
        let keyState: TerminalKeyState
        let autoWrap: Bool
        /// 布局完成回调是否已处理（回放 + 应用换行偏好），只做一次。
        private var didInitialize = false
        /// 内层终端视图（宽列模式下是外层 scrollView 的子视图）。
        weak var terminalView: SwiftTerm.TerminalView?
        /// 宽列模式的外层横向滚动容器。
        weak var hostScrollView: UIScrollView?
        /// 用户是否手动横向滚动过：手动接管后不再自动回中，避免与用户操作打架。
        private var userHorizontalScroll = false

        init(session: TerminalSession, keyState: TerminalKeyState, autoWrap: Bool) {
            self.session = session
            self.keyState = keyState
            self.autoWrap = autoWrap
        }

        /// 宽列模式下把光标列滚入可见窗口。用户手动横滚后停止自动跟随，避免抢操作。
        func followCursor(in view: SwiftTerm.TerminalView) {
            guard let scroll = hostScrollView,
                  scroll.contentSize.width > scroll.bounds.width,
                  !userHorizontalScroll else { return }
            // SwiftTerm 公开 caretFrame：origin.x 是光标像素列，width 是单列宽。
            let caret = view.caretFrame
            let caretX = caret.minX
            let cell = max(1, caret.width)
            let margin = cell * 3
            let visibleMin = scroll.contentOffset.x
            let visibleMax = visibleMin + scroll.bounds.width
            if caretX < visibleMin + margin {
                scroll.contentOffset.x = max(0, caretX - margin)
            } else if caretX + margin > visibleMax {
                scroll.contentOffset.x = min(scroll.contentSize.width - scroll.bounds.width, caretX + margin - scroll.bounds.width)
            }
        }

        /// UIScrollViewDelegate：识别用户手动横滚。
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            if scrollView === hostScrollView { userHorizontalScroll = true }
        }

        /// 键盘/快捷键产生的字节发往远端。Ctrl 锁定时把字母转成对应控制字符。
        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            // 用户一开始输入即恢复光标自动跟随（此前可能手动滚到别处看内容）。
            MainActor.assumeIsolated { userHorizontalScroll = false }
            let bytes: [UInt8] = data.map { byte in
                if keyState.ctrlLocked {
                    if byte >= 0x61 && byte <= 0x7A { return byte - 0x60 } // a-z -> 0x01...
                    if byte >= 0x41 && byte <= 0x5A { return byte - 0x40 } // A-Z -> 0x01...
                }
                return byte
            }
            MainActor.assumeIsolated { session.send(bytes) }
        }

        /// 视图列数确定后做一次初始化：应用换行偏好 + 回放历史。幂等。
        func initializeIfNeeded(_ view: SwiftTerm.TerminalView) {
            MainActor.assumeIsolated {
                guard !didInitialize else { return }
                didInitialize = true
                keyState.terminalView = view
                terminalView = view
                // 先应用换行偏好，再回放历史，保证排版一致。
                keyState.applyAutoWrap(autoWrap)
                session.byteBridge.markReady()
            }
        }

        /// SwiftTerm 布局后回调实际列行。首次回调时视图列数已确定——此刻才回放历史字节，
        /// 避免「按默认 80 列排版后再改列数」导致文字被裁半截。
        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            initializeIfNeeded(source)
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

    @ObservedObject private var session = TerminalSession.shared
    @StateObject private var keyState = TerminalKeyState()
    @Environment(\.dismiss) private var dismiss
    @State private var focusTick = 0
    @State private var showSettings = false
    @AppStorage("com.lone.lonepanel.terminal.fontSize") private var fontSize = 14.0
    @AppStorage("com.lone.lonepanel.terminal.autoWrap") private var autoWrap = true
    @AppStorage("com.lone.lonepanel.terminal.virtualColumns") private var virtualColumns = 100
    @State private var keyboardShown = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                terminalArea
                shortcutBar
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("SSH 终端")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(isPresented: $showSettings) { settingsPanel }
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
            Button { showSettings = true } label: {
                Image(systemName: "textformat.size")
            }
            .help("终端设置")
            .accessibilityLabel("终端设置")
        }
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 16) {
                Button { keyState.clearScreen() } label: {
                    Image(systemName: "trash")
                }
                .help("清屏")
                switch presentation {
                case .sheet:
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .accessibilityLabel("收起终端")
                case .pushed:
                    if session.userDisconnected {
                        Button {
                            Task { await session.activateForUser() }
                        } label: { Text("连接") }
                    } else {
                        Button { session.disconnect() } label: { Text("断开") }
                    }
                }
            }
        }
    }

    // MARK: - 终端显示区

    /// SwiftTerm 终端视图 + 连接状态覆盖层。
    /// 用 id 绑定字号：字号变化时重建视图并按新字号回放历史，重新排版。
    private var terminalArea: some View {
        TerminalHostView(
            session: session,
            keyState: keyState,
            focusTick: focusTick,
            fontSize: fontSize,
            autoWrap: autoWrap,
            virtualColumns: autoWrap ? 0 : virtualColumns
        )
        .id("term-\(fontSize)-\(autoWrap)-\(autoWrap ? 0 : virtualColumns)")
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
        .animation(.easeInOut, value: session.notice)
    }

    // MARK: - 快捷键栏

    /// 常驻一排 + Ctrl 锁定时展开的一排。所有按键限宽、按压变色 + 触感反馈。
    private var shortcutBar: some View {
        VStack(spacing: 8) {
            if keyState.ctrlLocked {
                // 展开行：只留最高频的三个，完整文字「Ctrl + X」撑宽。
                HStack(spacing: 8) {
                    comboKey("Ctrl + C", byte: 0x03)
                    comboKey("Ctrl + Z", byte: 0x1A)
                    comboKey("Ctrl + D", byte: 0x04)
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

    // MARK: - 设置面板

    private var settingsPanel: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("字号")
                            Spacer()
                            Text("\(Int(fontSize)) pt")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $fontSize, in: 11...22, step: 1)
                    }
                } header: {
                    Text("显示")
                }
                Section {
                    Toggle("自动换行", isOn: $autoWrap)
                    if !autoWrap {
                        HStack {
                            Text("虚拟列数")
                            Spacer()
                            Text(verbatim: "\(virtualColumns) cols")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { Double(virtualColumns) },
                            set: { virtualColumns = Int($0) }
                        ), in: 40...200, step: 10)
                    }
                } header: {
                    Text("排版")
                } footer: {
                    Text(autoWrap
                         ? "长行自动折行显示。"
                         : "按虚拟列数排版，可左右滑动查看完整长行。列数越大单行显示越多，但全屏程序（如 vim、htop）会按此宽度排布。")
                }
            }
            .navigationTitle("终端设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showSettings = false }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
