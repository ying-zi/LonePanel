import SwiftUI
import UIKit
import SwiftTerm

/// 终端的呈现方式，决定右上角操作按钮的语义。
enum TerminalPresentation {
    case sheet   // 悬浮按钮弹出：右上角为「收起」
    case pushed  // 设置页推入：右上角为「断开 / 连接」
}

/// 快捷键栏的共享状态。SwiftUI 按钮与 SwiftTerm 的 delegate 都读写它，
/// 实现「点 ⌃ 点亮并展开组合键、再点收起并解锁」的切换语义。
final class TerminalKeyState: ObservableObject {
    @Published var ctrlLocked = false
    /// SwiftTerm 视图引用，用于本地清屏。由 Coordinator 设置。
    weak var terminalView: SwiftTerm.TerminalView?

    func toggleCtrl() {
        ctrlLocked.toggle()
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

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let view = SwiftTerm.TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        // 禁用 SwiftTerm 自带键盘工具条，改用我们自己的混合 Ctrl 快捷键栏。
        view.inputAccessoryView = nil
        view.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        keyState.terminalView = view

        // 服务器字节 → SwiftTerm 仿真器。注册一次，覆盖冷启动先于视图建立的连接。
        session.byteBridge.register { [weak view] bytes in
            guard let view else { return }
            if Thread.isMainThread {
                view.feed(byteArray: bytes[...])
            } else {
                DispatchQueue.main.async { view.feed(byteArray: bytes[...]) }
            }
        }
        // 稍延迟弹出键盘（此时视图尚未上 window）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            view.becomeFirstResponder()
        }
        return view
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {
        // focusTick 变化时重新聚焦（连接从「未就绪」变为「就绪」时触发）。
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

        /// SwiftTerm 布局后回调实际列行，同步给远端 shell（vim/htop 全屏尺寸才正确）。
        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
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
/// 会话由 TerminalSession 全局持有——设置页与悬浮面板是同一会话、同一块屏幕。
struct TerminalView: View {
    var presentation: TerminalPresentation = .sheet

    @ObservedObject private var session = TerminalSession.shared
    @StateObject private var keyState = TerminalKeyState()
    @Environment(\.dismiss) private var dismiss
    @State private var focusTick = 0

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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                session.sendInterrupt()
            } label: {
                Text("⌃C")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }
            .disabled(!session.isReady)
            .help("中断当前命令 (Ctrl+C)")
        }
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 16) {
                Button { keyState.clearScreen() } label: {
                    Image(systemName: "trash")
                }
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
                        } label: {
                            Text("连接")
                        }
                    } else {
                        Button {
                            session.disconnect()
                        } label: {
                            Text("断开")
                        }
                    }
                }
            }
        }
    }

    /// SwiftTerm 终端视图 + 连接状态覆盖层。
    private var terminalArea: some View {
        TerminalHostView(session: session, keyState: keyState, focusTick: focusTick)
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

    /// 混合 Ctrl 快捷键栏：常规键常驻；点亮 ⌃ 后展开组合键并锁定修饰态。
    private var shortcutBar: some View {
        VStack(spacing: 6) {
            if keyState.ctrlLocked {
                HStack(spacing: 6) {
                    comboKey("⌃A", byte: 0x01)
                    comboKey("⌃E", byte: 0x05)
                    comboKey("⌃K", byte: 0x0B)
                    comboKey("⌃U", byte: 0x15)
                    comboKey("⌃D", byte: 0x04)
                    comboKey("⌃Z", byte: 0x1A)
                    comboKey("⌃L", byte: 0x0C)
                    comboKey("⌃C", byte: 0x03)
                }
            }

            HStack(spacing: 6) {
                controlKey("Tab", bytes: [0x09])
                controlKey("Esc", bytes: [0x1B])
                arrowKey("↑", sequence: [0x1B, 0x5B, 0x41])
                arrowKey("↓", sequence: [0x1B, 0x5B, 0x42])
                Spacer(minLength: 2)
                Button {
                    keyState.toggleCtrl()
                } label: {
                    Text("⌃")
                        .font(.system(size: 17, weight: .bold, design: .monospaced))
                        .frame(minWidth: 46, minHeight: 40)
                        .foregroundStyle(keyState.ctrlLocked ? .white : .primary)
                        .background(
                            RoundedRectangle(cornerRadius: 9)
                                .fill(keyState.ctrlLocked ? Color.accentColor : Color(uiColor: .secondarySystemBackground))
                        )
                }
                .accessibilityLabel(keyState.ctrlLocked ? "关闭 Ctrl 锁定" : "开启 Ctrl 锁定")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func controlKey(_ title: String, bytes: [UInt8]) -> some View {
        Button { session.send(bytes) } label: {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .frame(minWidth: 48, minHeight: 40)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 9))
        }
        .disabled(!session.isReady)
    }

    private func arrowKey(_ title: String, sequence: [UInt8]) -> some View {
        controlKey(title, bytes: sequence)
    }

    private func comboKey(_ title: String, byte: UInt8) -> some View {
        Button { session.send([byte]) } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        }
        .disabled(!session.isReady)
    }
}
