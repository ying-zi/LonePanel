import SwiftUI

/// 终端的呈现方式，决定右上角操作按钮的语义。
enum TerminalPresentation {
    case sheet   // 悬浮按钮弹出：右上角为「收起」
    case pushed  // 设置页推入：右上角为「断开 / 连接」
}

/// 内置 SSH 终端界面。上方等宽输出区，下方命令行输入。
/// 会话由 TerminalSession 全局持有——设置页与悬浮面板是同一会话、同一份输出。
struct TerminalView: View {
    var presentation: TerminalPresentation = .sheet

    @ObservedObject private var session = TerminalSession.shared
    @Environment(\.dismiss) private var dismiss
    @FocusState private var inputFocused: Bool
    @State private var command: String = ""
    @State private var history: [String] = []
    @State private var historyIndex: Int = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                outputArea
                Divider()
                inputBar
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("SSH 终端")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            // 用户打开终端即视为主动唤起：解除断开标记并连接（幂等）。
            .task { await session.activateForUser() }
            .onChange(of: session.isReady) { _, ready in
                if ready { focusInput() }
            }
            .onAppear {
                if session.isReady { focusInput() }
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
                Button {
                    session.clearOutput()
                } label: {
                    Image(systemName: "trash")
                }

                switch presentation {
                case .sheet:
                    // 悬浮面板：并非断开，只是收起。
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .accessibilityLabel("收起终端")
                case .pushed:
                    // 设置页：已有返回箭头，此按钮专用于断开/重连。
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

    /// 输入框在连接就绪前是 disabled，此时设焦点无效。
    /// 先复位再置 true，等呈现动画结束才聚焦，确保键盘真正弹出。
    private func focusInput() {
        inputFocused = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            inputFocused = true
        }
    }

    /// 等宽输出区。命令/输出/提示分色，随内容自动滚到底。
    private var outputArea: some View {
        ScrollView {
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(session.chunks) { chunk in
                        Text(chunk.text)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(color(for: chunk.kind))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(8)
                .onChange(of: session.revision) { _, _ in
                    withAnimation(.none) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .overlay {
            if session.isConnecting {
                ProgressView("正在连接…")
            } else if let error = session.errorMessage {
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
    }

    private func color(for kind: TerminalChunkKind) -> Color {
        switch kind {
        case .command: return Color.accentColor
        case .info: return .secondary
        case .output: return .primary
        }
    }

    /// 命令行输入区。两行高的圆角输入框（可继续换行滚动），右侧方块发送。
    private var inputBar: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("$")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.accentColor)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $command)
                    .font(.system(size: 14, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($inputFocused)
                    .scrollContentBackground(.hidden)
                    .frame(height: 46)
                    .disabled(!session.isReady)

                if command.isEmpty {
                    Text("输入命令…")
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .padding(.top, 4)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(uiColor: .separator), lineWidth: 0.5)
            }

            Button {
                submit()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10))
            }
            .disabled(!session.isReady || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("发送")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(uiColor: .systemBackground))
    }

    private func submit() {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let lines = command.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        command = ""
        for line in lines {
            history.append(line)
            session.send(command: line)
        }
        historyIndex = history.count
    }
}
