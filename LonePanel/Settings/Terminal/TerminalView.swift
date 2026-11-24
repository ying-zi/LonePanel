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
                        Image(systemName: "square.on.square")
                    }
                    .disabled(!session.isReady)
                    .help("中断 (Ctrl+C)")
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
            .onAppear { inputFocused = true }
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

    /// 命令行输入区。
    private var inputBar: some View {
        HStack(spacing: 8) {
            Text("$")
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.secondary)
            TextField("", text: $command)
                .font(.system(size: 14, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { submit() }
                .disabled(!session.isReady)
            Button {
                submit()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(!session.isReady || command.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private func submit() {
        let text = command
        guard !text.isEmpty else { return }
        command = ""
        history.append(text)
        historyIndex = history.count
        session.send(command: text)
    }
}
