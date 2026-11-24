import Foundation
import SwiftUI

/// 终端显示片段类型：命令用强调色、系统提示用次要色、其余为普通输出。
enum TerminalChunkKind {
    case command
    case output
    case info
}

struct TerminalChunk: Identifiable {
    let id = UUID()
    var text: String
    var kind: TerminalChunkKind
}

/// 终端会话状态：持有交互式 shell，负责读写循环。
/// 全局单例——悬浮终端与设置页终端共用同一会话，切 Tab 不丢。
@MainActor
final class TerminalSession: ObservableObject {
    static let shared = TerminalSession()

    /// 结构化终端内容。命令 / 输出 / 提示分色渲染。
    @Published private(set) var chunks: [TerminalChunk] = []
    /// 内容变更计数，驱动自动滚到底。
    @Published private(set) var revision = 0
    @Published private(set) var isConnecting = false
    @Published private(set) var isReady = false
    @Published private(set) var errorMessage: String?
    /// 用户在设置页主动断开后为 true：此后自动保活跳过，直到再次主动唤起终端。
    @Published private(set) var userDisconnected = false

    private var shell: SSHShell?
    private var readTask: Task<Void, Never>?
    /// 每次开 shell / 断开递增，用于判定读循环退出是「意外断开」还是「主动关闭」。
    private var generation = 0
    /// 跨数据包残留的 ANSI 转义状态，避免转义序列被从中间截断后露出碎片。
    private var ansiState: ANSIState = .normal
    /// 刚发出的命令，用于剥掉服务器回显，避免命令显示两次。
    private var pendingEcho: String?

    private init() {}

    // MARK: - 保活入口

    /// App 前台 / 自动场景调用。用户主动断开过时跳过，尊重其意图。
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

    /// 用户主动打开/唤起终端：解除断开标记并连接。
    func activateForUser() async {
        if userDisconnected {
            userDisconnected = false
            errorMessage = nil
        }
        await ensureAlive()
    }

    // MARK: - 连接 / 断开

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
            append(TerminalChunk(text: "\n", kind: .output))
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
                    await MainActor.run { self?.receive(bytes) }
                } catch {
                    break
                }
            }
            await MainActor.run {
                guard let self, self.generation == token else { return }
                // 读循环非主动退出 => 连接意外断开。清理并在保活范围内自动重连。
                self.shell = nil
                self.isReady = false
                SharedSSHConnection.shared.closeShell()
                self.appendInfo("\n[连接中断，正在重连…]\n")
                if !self.userDisconnected {
                    Task { await self.ensureAlive(forceReconnect: true) }
                }
            }
        }
    }

    // MARK: - 收发

    func send(_ bytes: [UInt8]) {
        shell?.send(bytes)
    }

    /// 发送命令并补回车。命令本身本地即时显示（强调色），并剥掉服务器回显。
    func send(command: String) {
        guard !command.isEmpty else { return }
        append(TerminalChunk(text: "› \(command)\n", kind: .command))
        pendingEcho = command
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

    // MARK: - 输出处理

    private func receive(_ bytes: [UInt8]) {
        let cleaned = Self.filterANSI(bytes, state: &ansiState)
        var text = String(decoding: cleaned, as: UTF8.self)

        // 剥掉刚刚这条命令的回显，避免与本地命令片段重复。
        if let echo = pendingEcho, let stripped = Self.stripEcho(text, command: echo) {
            text = stripped
            pendingEcho = nil
        }
        guard !text.isEmpty else { return }
        append(TerminalChunk(text: text, kind: .output))
    }

    private func append(_ chunk: TerminalChunk) {
        // 连续输出合并，减少 Text 数量。
        if chunk.kind == .output, let lastIndex = chunks.indices.last, chunks[lastIndex].kind == .output {
            var last = chunks[lastIndex]
            last.text += chunk.text
            chunks[lastIndex] = last
        } else {
            chunks.append(chunk)
        }

        // 限制缓冲，避免长期运行内存膨胀（保留尾部 200K 字符）。
        var total = chunks.reduce(0) { $0 + $1.text.count }
        while total > 200_000, let first = chunks.first {
            total -= first.text.count
            chunks.removeFirst()
        }
        revision &+= 1
    }

    private func appendInfo(_ text: String) {
        append(TerminalChunk(text: text, kind: .info))
    }

    func clearOutput() {
        chunks.removeAll()
        ansiState = .normal
        pendingEcho = nil
        revision &+= 1
    }

    /// 用户在设置页终端主动断开：记住意图，关闭 shell 与底层 SSH 连接，
    /// 使之后任何前台/前后台切换都不再自动连接，直到再次主动唤起终端。
    func disconnect() {
        userDisconnected = true
        generation += 1
        readTask?.cancel()
        readTask = nil
        shell?.close()
        shell = nil
        isReady = false
        pendingEcho = nil
        ansiState = .normal
        SharedSSHConnection.shared.disconnect()
        appendInfo("\n[连接已断开]\n")
    }

    // MARK: - ANSI 过滤

    private enum ANSIState {
        case normal
        case escape      // 收到 ESC
        case csi         // ESC [ 参数区
        case osc         // ESC ] 标题区
        case oscEscape   // OSC 中收到 ESC，等待 \ 结束
    }

    /// 在字节层剥离 ANSI 转义序列（颜色、光标、括号粘贴、OSC 标题等）。
    /// 用状态机跨越数据包边界，避免转义序列被切断后露出碎片。
    private static func filterANSI(_ bytes: [UInt8], state: inout ANSIState) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        for b in bytes {
            switch state {
            case .normal:
                if b == 0x1B {
                    state = .escape
                } else if b != 0x0D { // 丢弃回车，保留换行
                    out.append(b)
                }
            case .escape:
                if b == 0x5B { state = .csi }          // [
                else if b == 0x5D { state = .osc }     // ]
                else { state = .normal }               // 其余两字节转义直接吞掉
            case .csi:
                if b >= 0x40 && b <= 0x7E { state = .normal } // 最终字节
            case .osc:
                if b == 0x07 { state = .normal }        // BEL
                else if b == 0x1B { state = .oscEscape }
            case .oscEscape:
                state = (b == 0x5C) ? .normal : .osc   // ST = ESC \
            }
        }
        return out
    }

    /// 从新收到文本的开头剥掉刚发出命令的回显（形如 "ls\n"）。
    private static func stripEcho(_ text: String, command: String) -> String? {
        let trimmed = String(text.drop(while: { $0 == "\n" }))
        guard trimmed.hasPrefix(command) else { return nil }
        let rest = trimmed.dropFirst(command.count).drop(while: { $0 == "\n" })
        return String(rest)
    }
}
