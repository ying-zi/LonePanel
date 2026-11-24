import SwiftUI

/// 内置 SSH 终端界面。上方等宽输出区，下方命令行输入。
/// 会话由 TerminalSession 全局持有——设置页与悬浮面板是同一会话、同一份输出。
struct TerminalView: View {
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
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        session.sendInterrupt()
                    } label: {
                        Label("中断", systemImage: "xmark.circle")
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
                        Button("关闭") { dismiss() }
                    }
                }
            }
            .task { await session.start() }
            // 连接刚就绪（新连接）时聚焦。
            .onChange(of: session.isReady) { _, ready in
                if ready { focusInput() }
            }
            // 复用已连接的会话时，进场即聚焦。
            .onAppear {
                if session.isReady { focusInput() }
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

    /// 等宽输出区。用 Text 逐段渲染，配合 ScrollView 自动滚到底。
    private var outputArea: some View {
        ScrollView {
            ScrollViewReader { proxy in
                Text(session.output)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .id("bottom")
                    .onChange(of: session.output) { _, _ in
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
                    Button("重试") { Task { await session.start() } }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
            }
        }
    }

    /// 命令行输入区。统一底色的多行文本框，自动聚焦，右下方发送。
    private var inputBar: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text("$")
                    .font(.system(size: 14, design: .monospaced, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 9)

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $command)
                        .font(.system(size: 14, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($inputFocused)
                        .scrollContentBackground(.hidden)
                        .frame(height: 80)
                        .disabled(!session.isReady)
                        .toolbar {
                            ToolbarItemGroup(placement: .keyboard) {
                                Spacer()
                                Button("发送") { submit() }
                                    .disabled(!session.isReady || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }

                    if command.isEmpty {
                        Text("输入命令…")
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .padding(.top, 9)
                            .allowsHitTesting(false)
                    }
                }
            }

            HStack {
                Spacer()
                Button {
                    submit()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                }
                .disabled(!session.isReady || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground))
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
