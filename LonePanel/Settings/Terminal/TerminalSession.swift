import Foundation
import SwiftUI

/// 终端会话状态：持有交互式 shell，负责读写循环。
/// 全局单例——悬浮终端与设置页终端共用同一会话，切 Tab 不丢。
@MainActor
final class TerminalSession: ObservableObject {
    static let shared = TerminalSession()

    /// 终端显示文本（手动追加，避免 SwiftUI Text 频繁重排）。
    @Published private(set) var output: String = ""
    @Published private(set) var isConnecting = false
    @Published private(set) var isReady = false
    @Published private(set) var errorMessage: String?

    private var shell: SSHShell?
    private var readTask: Task<Void, Never>?

    private init() {}

    /// 连接并启动 shell。已就绪则直接返回。
    func start() async {
        if isReady, shell != nil { return }
        guard await SharedSSHConnection.shared.ensureConnected() else {
            errorMessage = SharedSSHConnection.shared.lastError
            return
        }
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        do {
            let shell = try await SharedSSHConnection.shared.openShell()
            self.shell = shell
            isReady = true
            append("\n")
            startReading(shell)
        } catch {
            errorMessage = SSHSession.describe(error)
            isReady = false
        }
    }

    private func startReading(_ shell: SSHShell) {
        readTask?.cancel()
        readTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let bytes = try await shell.receive()
                    guard !bytes.isEmpty else { continue }
                    let text = String(decoding: bytes, as: UTF8.self)
                    await MainActor.run { self?.append(text) }
                } catch {
                    break
                }
            }
        }
    }

    /// 发送原始字节（命令 + 回车由调用方拼好）。
    func send(_ bytes: [UInt8]) {
        shell?.send(bytes)
    }

    /// 发送命令文本并自动补回车。
    func send(command: String) {
        var line = Array(command.utf8)
        line.append(0x0D) // \r
        send(line)
    }

    /// Ctrl+C：发送 ASCII 0x03 中断前台进程。
    func sendInterrupt() {
        send([0x03])
    }

    func resize(columns: Int, rows: Int) {
        shell?.resize(columns: columns, rows: rows)
    }

    private func append(_ text: String) {
        output.append(text)
        // 限制缓冲，避免长期运行内存膨胀（保留尾部 200K 字符）。
        if output.count > 200_000 {
            output = String(output.suffix(200_000))
        }
    }

    func clearOutput() {
        output = ""
    }

    /// 断开当前 shell（下次打开会重连）。
    func terminate() {
        readTask?.cancel()
        readTask = nil
        shell?.close()
        shell = nil
        isReady = false
        SharedSSHConnection.shared.closeShell()
    }
}
