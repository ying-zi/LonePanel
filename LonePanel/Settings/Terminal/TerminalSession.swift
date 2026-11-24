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
    /// 用户在设置页主动断开后为 true：此后所有自动连接都跳过，直到用户主动重连。
    @Published private(set) var userDisconnected = false

    private var shell: SSHShell?
    private var readTask: Task<Void, Never>?
    /// 每次开 shell / 断开递增，用于判定读循环退出是「意外断开」还是「主动关闭」。
    private var generation = 0

    private init() {}

    // MARK: - 保活入口

    /// App 前台 / 打开终端时调用。只要用户没主动断开，就确保底层连接与 shell 就绪。
    /// forceReconnect：shell 意外断开时强制重建底层 SSH 连接（标志可能未反映真实断线）。
    func ensureAlive(forceReconnect: Bool = false) async {
        guard !userDisconnected else { return }
        let ok = await SharedSSHConnection.shared.ensureConnected(force: forceReconnect)
        guard ok else {
            errorMessage = SharedSSHConnection.shared.lastError
            return
        }
        if isReady, shell != nil, !forceReconnect { return }
        await openShell()
    }

    /// 用户主动重连（设置页终端「连接」按钮）：解除断开标记并连接。
    func reconnect() async {
        userDisconnected = false
        errorMessage = nil
        await ensureAlive()
    }

    // MARK: - 连接 / 断开

    /// 启动 shell 读循环。内外统一走 ensureAlive，不再有独立 start 入口。
    private func openShell() async {
        generation += 1
        let token = generation
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        do {
            let newShell = try await SharedSSHConnection.shared.openShell()
            self.shell = newShell
            isReady = true
            append("\n")
            startReading(newShell, token: token)
        } catch {
            errorMessage = SSHSession.describe(error)
            isReady = false
        }
    }

    private func startReading(_ shell: SSHShell, token: Int) {
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
            await MainActor.run {
                guard let self, self.generation == token else { return }
                // 读循环非主动退出 => 连接意外断开。清理并在前台保活范围内自动重连。
                self.shell = nil
                self.isReady = false
                SharedSSHConnection.shared.closeShell()
                if !self.userDisconnected {
                    Task { await self.ensureAlive(forceReconnect: true) }
                }
            }
        }
    }

    // MARK: - 收发

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

    /// 用户在设置页终端主动断开：记住意图，关闭 shell 与底层 SSH 连接，
    /// 并作废读循环，使之后任何前台/前台切换都不再自动连接。
    func disconnect() {
        userDisconnected = true
        generation += 1
        readTask?.cancel()
        readTask = nil
        shell?.close()
        shell = nil
        isReady = false
        SharedSSHConnection.shared.disconnect()
        append("\n[连接已断开]\n")
    }
}
