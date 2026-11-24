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
}

/// SwiftTerm 官方 TerminalView 的 SwiftUI 包装。
private struct TerminalHostView: UIViewRepresentable {
    let session: TerminalSession
    let keyState: TerminalKeyState
    let focusTick: Int
    let fontSize: Double

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            context.coordinator.initializeIfNeeded(view)
            view.becomeFirstResponder()
        }
        return view
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {
        if focusTick > 0 {
            DispatchQueue.main.async { uiView.becomeFirstResponder() }
        }
    }

    static func dismantleUIView(_ uiView: SwiftTerm.TerminalView, coordinator: Coordinator) {
        uiView.terminalDelegate = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, keyState: keyState)
    }

    final class Coordinator: TerminalViewDelegate {
        let session: TerminalSession
        let keyState: TerminalKeyState
        /// 布局完成回调是否已处理（回放历史），只做一次。
        private var didInitialize = false

        init(session: TerminalSession, keyState: TerminalKeyState) {
            self.session = session
            self.keyState = keyState
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
    /// 字号面板是否内联展开（不再用模态弹窗，避免遮挡键盘）。
    @State private var showFontPanel = false
    @AppStorage("com.lone.lonepanel.terminal.fontSize") private var fontSize = 14.0
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
                Image(systemName: "textformat.size")
                    .foregroundStyle(showFontPanel ? TerminalTheme.lockBlue : Color.primary)
            }
            .help("字号设置")
            .accessibilityLabel(showFontPanel ? "收起字号设置" : "字号设置")
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
            fontSize: fontSize
        )
        .id("term-\(fontSize)")
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
        // 内联字号面板：悬浮在终端顶部，不弹模态窗，键盘在底部互不遮挡。
        .overlay(alignment: .topLeading) {
            if showFontPanel { fontPanel }
        }
        .animation(.easeInOut, value: session.notice)
        .animation(.easeInOut(duration: 0.2), value: showFontPanel)
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
}
