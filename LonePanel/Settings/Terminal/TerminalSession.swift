import Foundation
import SwiftUI

/// 线程安全的字节桥：读循环在后台线程投递，SwiftUI 视图在主线程注册落地目标。
/// 用独立对象而非 @MainActor 属性，避免大量输出时跨线程隔离开销。
/// 同时缓存原始字节流——视图重建（收起再开 / 冷启动连接先于视图）时回放，
/// 让 SwiftTerm 重建屏幕，不丢历史内容。
final class TerminalByteBridge {
    private let lock = NSLock()
    private var handler: (([UInt8]) -> Void)?
    private var buffer = [UInt8]()
    private let maxBuffer = 256 * 1024
    /// 视图是否已就绪（布局完成、列数确定）。未就绪时只缓存字节，不回放、不实时投递，
    /// 避免以默认 80 列排版导致后续布局变化后文字被裁半截。
    private var viewReady = false

    /// 注册落地目标。此时视图尚未布局完成，只登记 handler，等待 ready() 后统一回放。
    func register(_ handler: (([UInt8]) -> Void)?) {
        lock.lock()
        self.handler = handler
        self.viewReady = false
        lock.unlock()
    }

    /// 视图布局完成、列数确定后调用：一次性回放缓存的历史字节，随后转入实时投递。
    func markReady() {
        lock.lock()
        guard !viewReady, let handler else { lock.unlock(); return }
        let backlog = buffer
        viewReady = true
        lock.unlock()
        // 回放历史（此时视图列数已正确）。feed 不会重入本桥，安全。
        if !backlog.isEmpty { handler(backlog) }
    }

    func deliver(_ bytes: [UInt8]) {
        lock.lock()
        buffer.append(contentsOf: bytes)
        if buffer.count > maxBuffer {
            buffer.removeFirst(buffer.count - maxBuffer)
        }
        let ready = viewReady
        let handler = self.handler
        lock.unlock()
        // 就绪后实时投递；未就绪只缓存，等 markReady 统一回放。
        if ready { handler?(bytes) }
    }

    /// 屏幕被外部重置（如字号变化触发 SwiftTerm resetFont → resetToInitialState 清屏）后，
    /// 重喂缓存字节重建画面，避免历史丢失。与 markReady 不同：不切 viewReady，可重复调用。
    func replay() {
        lock.lock()
        guard viewReady, !buffer.isEmpty else { lock.unlock(); return }
        let backlog = buffer
        let handler = self.handler
        lock.unlock()
        handler?(backlog)
    }

    func reset() {
        lock.lock()
        buffer.removeAll()
        viewReady = false
        lock.unlock()
    }
}

/// 终端会话：持有交互式 shell，负责字节级收发与保活。
/// 终端仿真（ANSI 解析、屏幕渲染、行编辑、键盘输入）交给 SwiftTerm 的 TerminalView。
/// 全局单例——悬浮终端与设置页终端共用同一会话、同一块屏幕。
@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    /// 注入式会话需要唯一标识以配合 .sheet(item:)。
    let id = UUID()
    static let shared = TerminalSession()

    @Published private(set) var isConnecting = false
    @Published private(set) var isReady = false
    @Published private(set) var errorMessage: String?
    /// 用户在设置页主动断开后为 true：此后自动保活跳过，直到再次主动唤起终端。
    @Published private(set) var userDisconnected = false
    /// 瞬时提示（如「连接中断，正在重连…」），由 UI 以 toast 呈现。
    @Published private(set) var notice: String?

    /// 字节桥：终端视图注册落地目标，服务器字节直接喂给 SwiftTerm 仿真器。
    /// 用桥对象而非 Published，避免把大量字节塞进 SwiftUI 的视图更新通道。
    let byteBridge = TerminalByteBridge()

    private var shell: SSHShell?
    private var readTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    /// 每次开 shell / 断开递增，用于判定读循环退出是「意外断开」还是「主动关闭」。
    private var generation = 0

    /// 注入式为 Docker 容器终端服务：带 PTY 执行指定命令，且会话结束不自动重连。
    /// 默认（单例）保持系统终端行为：开默认 shell、断线自动重连。
    private let execCommand: String?
    private let autoReconnect: Bool

    init(execCommand: String? = nil, autoReconnect: Bool = true) {
        self.execCommand = execCommand
        self.autoReconnect = autoReconnect
    }

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
            // 注入命令时走独立 exec 通道（docker exec），否则开默认 shell。
            let newShell: SSHShell
            if let command = execCommand {
                newShell = try await SharedSSHConnection.shared.openExecShell(command: command)
            } else {
                newShell = try await SharedSSHConnection.shared.openShell()
            }
            self.shell = newShell
            // 新连接 = 新会话，清掉上一次会话的回放缓冲。
            byteBridge.reset()
            isReady = true
            startReading(newShell, token: token)
        } catch {
            errorMessage = SSHSession.describe(error)
            isReady = false
        }
    }

    private func startReading(_ shell: SSHShell, token: Int) {
        readTask?.cancel()
        // 捕获桥对象，读循环在后台线程直接喂给 SwiftTerm（其 feed 线程安全），
        // 不经过 MainActor，避免大量输出时阻塞 UI。
        let bridge = byteBridge
        readTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let bytes = try await shell.receive()
                    guard !bytes.isEmpty else { continue }
                    bridge.deliver(bytes)
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
                if self.autoReconnect {
                    // 系统终端：断线自动重连。
                    self.showNotice("[连接中断，正在重连…]")
                    if !self.userDisconnected {
                        Task { await self.ensureAlive(forceReconnect: true) }
                    }
                } else {
                    // 容器终端：会话结束即停（用户 exit 或容器退出），不重连、只提示。
                    self.showNotice("[会话已结束]")
                }
            }
        }
    }

    // MARK: - 收发

    /// 把原始字节发给远端 shell（键盘输入、快捷键产生的控制字符都走这里）。
    func send(_ bytes: [UInt8]) {
        shell?.send(bytes)
    }

    /// Ctrl+C：发送 ASCII 0x03 中断前台进程。
    func sendInterrupt() {
        send([0x03])
    }

    func resize(columns: Int, rows: Int) {
        shell?.resize(columns: columns, rows: rows)
    }

    // MARK: - 提示

    private func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            self.notice = nil
        }
    }

    /// 用户在设置页终端主动断开：记住意图，关闭 shell 与底层 SSH 连接，
    /// 使之后任何前台/前后台切换都不再自动连接，直到再次主动唤起终端。
    func disconnect() {
        userDisconnected = true
        closeShellOnly()
        // 只有系统终端（单例）主动断开时才关闭共享连接；容器终端退出不动全局连接。
        if execCommand == nil {
            SharedSSHConnection.shared.disconnect()
        }
        showNotice("[连接已断开]")
    }

    /// 容器终端视图退出：仅关闭本会话的 exec 通道，不触碰共享 SSH 连接。
    func closeForContainer() {
        closeShellOnly()
    }

    private func closeShellOnly() {
        generation += 1
        readTask?.cancel()
        readTask = nil
        shell?.close()
        shell = nil
        isReady = false
    }
}
