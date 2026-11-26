import Foundation
import SwiftUI

/// 终端会话所依赖的 SSH 连接能力。系统终端与容器终端可注入不同连接：
/// - 系统终端 → SharedSSHConnection（跨模块复用的通用连接）
/// - 容器终端 → DockerSSHConnection（Docker 业务已验证可用的连接）
/// 两者都提供「确保连接 + 开 shell」能力，TerminalSession 不关心具体是哪一条。
@MainActor
protocol SSHConnectionProviding: AnyObject {
    var lastError: String? { get }
    @discardableResult
    func ensureConnected(force: Bool) async -> Bool
    func openShell() async throws -> SSHShell
    func openExecShell(command: String) async throws -> SSHShell
    func closeShell()
    func disconnect()
}

// 两条连接都实现同一协议；它们的方法签名已一致，此处仅声明遵循。
extension SharedSSHConnection: SSHConnectionProviding {}
extension DockerSSHConnection: SSHConnectionProviding {}

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

    /// 新会话开始：清空回放缓冲。
    /// 注意：绝不重置 viewReady —— 视图一旦布局完成并回放过，它就已经"活着"，
    /// 后续服务器字节应当实时投递。若这里把 viewReady 打回 false，而 markReady
    /// 的 didInitialize 守卫又只允许回放一次，则开 shell 晚于视图就绪时
    /// （仅终端模块冷启动、容器终端）所有输出只进缓存不落地 → 空壳。
    func reset() {
        lock.lock()
        buffer.removeAll()
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
    /// 开 shell 任务合并：冷启动保活与视图唤起可能并发，合并为一次，杜绝双 shell 竞争。
    private var openTask: Task<Bool, Never>?
    /// 每次开 shell / 断开递增，用于判定读循环退出是「意外断开」还是「主动关闭」。
    private var generation = 0
    /// 打开当前 shell 时记下的服务器代次。切服后代次变化，ensureAlive 不再复用旧 shell，
    /// 避免"终端仍连着旧服务器"——这是跨模块联动（如网站反代→容器详情）正确性的前提。
    private var shellEpoch = -1

    /// 注入式为 Docker 容器终端服务：带 PTY 执行指定命令，且会话结束不自动重连。
    /// 默认（单例）保持系统终端行为：开默认 shell、断线自动重连。
    private let execCommand: String?
    private let autoReconnect: Bool
    /// 承载本会话的 SSH 连接。系统终端用通用连接，容器终端注入 Docker 连接。
    private let connection: any SSHConnectionProviding

    init(
        connection: any SSHConnectionProviding = SharedSSHConnection.shared,
        execCommand: String? = nil,
        autoReconnect: Bool = true
    ) {
        self.connection = connection
        self.execCommand = execCommand
        self.autoReconnect = autoReconnect
    }

    /// 是否系统终端（单例默认 shell）。容器 exec 终端为 false——一次性会话，不显示重连。
    var isSystemTerminal: Bool { execCommand == nil }

    // MARK: - 保活入口

    /// App 前台 / 自动场景调用。用户主动断开过时跳过，尊重其意图。
    /// 建连 + 开 shell 全程合并为单一任务：冷启动保活、视图唤起、前后台切换即使并发，
    /// 也只会开一个 shell，从根上杜绝双 shell 竞争导致的「打开空白 / 连不上」。
    func ensureAlive(forceReconnect: Bool = false) async {
        guard !userDisconnected else { return }
        let currentEpoch = ServerSession.shared.connectionEpoch
        // 切服（或删服改默认）后代次变化：旧 shell 连的是旧服务器，必须先主动关闭，
        // 否则短路复用会让所有终端操作打到旧机器。容器 exec 终端是一次性会话，切服即停。
        let serverChanged = shellEpoch != currentEpoch
        if serverChanged && shell != nil { closeShellOnly() }
        if isReady, shell != nil, !forceReconnect, !serverChanged { return }
        if let openTask {
            await openTask.value
            return
        }
        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            // 服务器已变时用 force 重建底层连接，杜绝复用连向旧机器的 SSH 会话。
            let ok = await self.connection.ensureConnected(force: forceReconnect || serverChanged)
            guard ok else {
                self.errorMessage = self.connection.lastError
                return false
            }
            await self.openShell(epoch: currentEpoch)
            return self.isReady
        }
        openTask = task
        await task.value
        openTask = nil
    }

    /// 用户主动打开/唤起终端：解除断开标记并连接。
    func activateForUser() async {
        if userDisconnected {
            userDisconnected = false
            errorMessage = nil
        }
        await ensureAlive()
        // 首次唤起若因服务器尚未就绪 / 网络抖动失败，延迟重试一次——
        // 覆盖「只开终端模块、App 刚启动就进终端」连不上的场景。
        // 仅系统终端自动重试；容器 exec 终端由 Docker 连接保障，一次性会话不纠缠。
        guard isSystemTerminal, !isReady, errorMessage != nil else { return }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        if !isReady, !userDisconnected {
            await ensureAlive(forceReconnect: true)
        }
    }

    /// 用户主动重新连接：强制重建底层 SSH 连接与交互 shell。
    /// 用于连接卡死、认证变更、网络恢复等「普通复用连接救不回来」的场景——
    /// 直接跳过 shell 复用，force 重建连接；成功后清掉错误并回放新会话。
    func reconnect() async {
        userDisconnected = false
        errorMessage = nil
        // 先等正在进行中的自动建连结束，避免它随后覆盖本次重连的 shell。
        if let openTask { await openTask.value; self.openTask = nil }
        // 让旧读循环失效（generation++），避免它检测到断线后触发自动重连、与本次重连争用。
        closeShellOnly()
        isConnecting = true
        defer { isConnecting = false }
        let ok = await connection.ensureConnected(force: true)
        guard ok else {
            errorMessage = connection.lastError
            return
        }
        // 底层连接已强制重建，开一个全新 shell 完成重连。
        await openShell()
    }

    // MARK: - 连接 / 断开

    private func openShell(epoch: Int? = nil) async {
        generation += 1
        let token = generation
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        do {
            // 注入命令时走 exec 通道（docker exec），否则开默认 shell。
            // 两者都走本会话注入的连接，系统终端与容器终端物理隔离、互不干扰。
            let newShell: SSHShell
            if let command = execCommand {
                newShell = try await connection.openExecShell(command: command)
            } else {
                newShell = try await connection.openShell()
            }
            self.shell = newShell
            self.shellEpoch = epoch ?? ServerSession.shared.connectionEpoch
            // 新连接 = 新会话，清掉上一次会话的回放缓冲（保留 viewReady）。
            byteBridge.reset()
            // 系统终端注入一条本地连接横幅：让"连接成功"有明确视觉反馈
            // （用户反馈空壳时无法判断是否连上）。容器 exec 终端不注入，避免污染 docker exec 输出。
            if execCommand == nil {
                let name = ServerSession.shared.currentServer?.name ?? L10n.t("Server")
                // 只保留"已连接到"这一行；第二行提示语已按反馈移除。
                let banner = "\r\n\u{1B}[1;32m● \(L10n.t("Connected to")) \(name)\u{1B}[0m\r\n\r\n"
                byteBridge.deliver(Array(banner.utf8))
            }
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
                self.connection.closeShell()
                if self.autoReconnect {
                    // 系统终端：断线自动重连。
                    self.showNotice(L10n.t("[Connection lost, reconnecting...]"))
                    if !self.userDisconnected {
                        Task { await self.ensureAlive(forceReconnect: true) }
                    }
                } else {
                    // 容器终端：会话结束即停（用户 exit 或容器退出），不重连、只提示。
                    self.showNotice(L10n.t("[Session ended]"))
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
        // 只有系统终端（单例）主动断开时才关闭其通用连接；容器终端退出不动连接。
        if execCommand == nil {
            connection.disconnect()
        }
        showNotice(L10n.t("[Disconnected]"))
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
