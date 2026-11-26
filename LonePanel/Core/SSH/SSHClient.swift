import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// 测试连接使用的凭证。凭证本体只在内存中流转，落盘交给根 Core/Keychain。
enum SSHAuthCredential {
    case password(String)
    case privateKey(String) // PEM 文本
}

struct SSHExecResult {
    let exitStatus: Int
    let stdout: String
    let stderr: String
}

enum SSHConnectionError: LocalizedError {
    case invalidPort
    case invalidChannelType
    case invalidPrivateKey(String)
    case authenticationUnsupported
    case authenticationFailed
    case timedOut
    case closedUnexpectedly
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .invalidPort: return L10n.t("Port must be between 1 and 65535")
        case .invalidChannelType: return L10n.t("Server rejected the session channel")
        case .invalidPrivateKey(let text): return text
        case .authenticationUnsupported:
            return L10n.t("Server does not accept the chosen auth method. Check whether key/password auth is enabled.")
        case .authenticationFailed: return L10n.t("Authentication failed: incorrect username or credential")
        case .timedOut: return L10n.t("Connection timed out. Check the address, port and network connectivity.")
        case .closedUnexpectedly: return L10n.t("Connection closed by the server, usually due to auth failure or host rejection.")
        case .underlying(let text): return text
        }
    }
}

/// 根 Core/SSH 的连接封装：建立 SSH 连接、认证、执行远端命令。
/// 具体业务模块通过 ServerSession.currentServer 取得连接参数后使用它，不自行管理通道。
final class SSHSession {
    private let group: MultiThreadedEventLoopGroup
    /// internal 可见性：供同模块 SSHSubsystem 扩展开启 subsystem 子通道。
    let channel: Channel
    /// 在途命令注册表：父通道错误时广播给所有正在执行的命令。
    /// 支持并发——Docker 等模块进页面会同时拉容器、镜像、系统信息。
    private let gateRegistry: GateRegistry

    init(
        host: String,
        port: Int,
        username: String,
        credential: SSHAuthCredential,
        timeoutSeconds: Int = 12
    ) async throws {
        guard port > 0, port <= 65535 else { throw SSHConnectionError.invalidPort }

        let password: String?
        let privateKey: NIOSSHPrivateKey?
        switch credential {
        case .password(let value):
            password = value
            privateKey = nil
        case .privateKey(let pem):
            password = nil
            do {
                privateKey = try PrivateKeyParser.parse(pem)
            } catch let error as PrivateKeyError {
                throw SSHConnectionError.invalidPrivateKey(error.localizedDescription)
            }
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        let gateRegistry = GateRegistry()
        self.gateRegistry = gateRegistry

        let auth = AuthDelegate(username: username, password: password, privateKey: privateKey)
        let hostKey = HostKeyDelegate()

        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.seconds(Int64(timeoutSeconds)))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let sync = channel.pipeline.syncOperations
                    let handler = NIOSSHHandler(
                        role: .client(
                            .init(
                                userAuthDelegate: auth,
                                serverAuthDelegate: hostKey
                            )
                        ),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try sync.addHandler(handler)
                    try sync.addHandler(ParentErrorHandler(registry: gateRegistry))
                }
            }

        let channel: Channel = try await withCheckedThrowingContinuation { continuation in
            bootstrap.connect(host: host, port: port).whenComplete { result in
                switch result {
                case .success(let established): continuation.resume(returning: established)
                case .failure(let error):
                    continuation.resume(throwing: SSHConnectionError.underlying(Self.describe(error)))
                }
            }
        }
        self.channel = channel

        // 立即开一个通道执行 true，确认认证已经完成，而不是只完成了 TCP 握手。
        _ = try await execute("true", timeoutSeconds: timeoutSeconds)
    }

    /// 执行远端命令。返回退出码、标准输出与标准错误。
    /// 可并发调用：每条命令独立子通道与 Promise，父通道错误会广播让所有在途命令一起失败。
    func execute(_ command: String, timeoutSeconds: Int = 20) async throws -> SSHExecResult {
        let promise = group.next().makePromise(of: SSHExecResult.self)
        let gate = PromiseGate(promise)
        gateRegistry.add(gate)
        defer { gateRegistry.remove(gate) }

        let timeoutWork = DispatchWorkItem {
            gate.fail(SSHConnectionError.timedOut)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: timeoutWork)
        defer { timeoutWork.cancel() }

        channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
            switch result {
            case .failure(let error):
                gate.fail(error)
            case .success(let ssh):
                let childPromise = self.channel.eventLoop.makePromise(of: Channel.self)
                ssh.createChannel(childPromise) { child, type in
                    guard type == .session else {
                        return child.eventLoop.makeFailedFuture(SSHConnectionError.invalidChannelType)
                    }
                    return child.eventLoop.makeCompletedFuture {
                        let sync = child.pipeline.syncOperations
                        try sync.addHandler(ExecCollector(command: command, gate: gate))
                        try sync.addHandler(ChildErrorHandler(gate: gate))
                    }
                }
                childPromise.futureResult.whenComplete { childResult in
                    if case .failure(let error) = childResult { gate.fail(error) }
                }
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            promise.futureResult.whenComplete { result in
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    func close() {
        _ = channel.close(promise: nil)
        try? group.syncShutdownGracefully()
    }

    deinit { close() }

    /// 把任意错误翻译成给用户看的中文提示，绝不暴露 NIO / NIOSSH / Posix 原始报错。
    static func describe(_ error: Error) -> String {
        switch error {
        case let e as SSHConnectionError: return e.localizedDescription
        case let e as PrivateKeyError: return e.localizedDescription
        default: return mapUnderlying(String(describing: error))
        }
    }

    /// 依据底层错误关键字，映射为具体、可读的中文原因。
    private static func mapUnderlying(_ raw: String) -> String {
        let text = raw.lowercased()
        if text.contains("timed out") || text.contains("timeout") {
            return L10n.t("Connection timed out. Check your network and whether the server is online.")
        }
        if text.contains("connection refused") || text.contains("econnrefused") || text.contains("refused") {
            return L10n.t("Connection refused. Verify the address and port and that SSH is running.")
        }
        if text.contains("nodename nor servname") || text.contains("getaddrinfo") ||
            text.contains("name or service not known") || text.contains("dns") {
            return L10n.t("Cannot resolve the server address. Check that the address is correct.")
        }
        if text.contains("network is unreachable") || text.contains("no route to host") ||
            text.contains("networkunreachable") {
            return L10n.t("Network unreachable. Check your network connection.")
        }
        if text.contains("authentication") || text.contains("permission denied") || text.contains("authfail") {
            return L10n.t("Authentication failed. Check your username and password or private key.")
        }
        if text.contains("host key") || text.contains("handshake") || text.contains("algorithm") ||
            text.contains("kex") {
            return L10n.t("SSH negotiation failed. The server configuration may be incompatible with this app.")
        }
        if text.contains("reset by peer") || text.contains("broken pipe") || text.contains("eof") ||
            text.contains("closed") {
            return L10n.t("Connection interrupted by the server. Retry later or check server status.")
        }
        return L10n.t("Connection failed. Check the address, port and network, then retry.")
    }
}

// MARK: - 测试连接

extension SSHSession {
    /// 真实 TCP + SSH 握手 + 认证 + 命令通道验证。成功返回可读提示。
    static func test(
        host: String,
        port: Int,
        username: String,
        credential: SSHAuthCredential,
        timeoutSeconds: Int = 12
    ) async throws -> String {
        let session = try await SSHSession(
            host: host,
            port: port,
            username: username,
            credential: credential,
            timeoutSeconds: timeoutSeconds
        )
        defer { session.close() }
        return L10n.t("Connected: SSH handshake and authentication succeeded; command channel is ready.")
    }
}

// MARK: - 内部协作类型

/// 保证 Promise 只兑现一次，避免超时与错误回调竞争。
private final class PromiseGate {
    private let lock = NSLock()
    private var finished = false
    let promise: EventLoopPromise<SSHExecResult>

    init(_ promise: EventLoopPromise<SSHExecResult>) { self.promise = promise }

    func succeed(_ result: SSHExecResult) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        promise.succeed(result)
    }

    func fail(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        promise.fail(error)
    }
}

/// 在途命令注册表。取代原先只存一条命令的单槽位：
/// 单槽位下并发的第二条命令会覆盖第一条，父通道错误只能通知到最后一条，
/// 前面的命令只能干等超时（Docker 并发拉数据时必然踩雷）。
/// 现在父通道级错误广播给所有在途 gate；每条命令自己的子通道错误仍只影响自己。
private final class GateRegistry {
    private let lock = NSLock()
    private var gates: [ObjectIdentifier: PromiseGate] = [:]

    func add(_ gate: PromiseGate) {
        lock.lock(); gates[ObjectIdentifier(gate)] = gate; lock.unlock()
    }

    func remove(_ gate: PromiseGate) {
        lock.lock(); gates.removeValue(forKey: ObjectIdentifier(gate)); lock.unlock()
    }

    /// 父通道错误：连接级故障，所有在途命令一起失败。
    func failAll(_ error: Error) {
        lock.lock()
        let all = Array(gates.values)
        gates.removeAll()
        lock.unlock()
        for gate in all { gate.fail(error) }
    }
}

private final class AuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let password: String?
    private let privateKey: NIOSSHPrivateKey?
    private let lock = NSLock()
    private var attempts = 0

    init(username: String, password: String?, privateKey: NIOSSHPrivateKey?) {
        self.username = username
        self.password = password
        self.privateKey = privateKey
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        lock.lock()
        attempts += 1
        let attempt = attempts
        lock.unlock()

        if attempt > 2 {
            nextChallengePromise.fail(SSHConnectionError.authenticationFailed)
            return
        }
        if let key = privateKey, availableMethods.contains(.publicKey) {
            let offer = NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "",
                offer: .privateKey(.init(privateKey: key))
            )
            nextChallengePromise.succeed(offer)
        } else if let password = password, availableMethods.contains(.password) {
            let offer = NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "",
                offer: .password(.init(password: password))
            )
            nextChallengePromise.succeed(offer)
        } else if availableMethods.isEmpty {
            nextChallengePromise.fail(SSHConnectionError.authenticationFailed)
        } else {
            nextChallengePromise.fail(SSHConnectionError.authenticationUnsupported)
        }
    }
}

/// 首版接受所有主机密钥；后续可在根 Core/SSH 增加 known_hosts 校验。
private final class HostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

/// 父通道的错误转发给所有在途命令。
private final class ParentErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private let registry: GateRegistry
    init(registry: GateRegistry) { self.registry = registry }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        registry.failAll(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        registry.failAll(SSHConnectionError.closedUnexpectedly)
        context.fireChannelInactive()
    }
}

private final class ChildErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private let gate: PromiseGate
    init(gate: PromiseGate) { self.gate = gate }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        gate.fail(error)
        context.close(promise: nil)
    }
}

private final class ExecCollector: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let gate: PromiseGate
    private var stdout = Data()
    private var stderr = Data()
    /// ExitStatus 与 stdout 走两条独立 inbound 路径，退出码可能先于最后几批数据到达。
    /// 收到退出码后不能立即兑现，否则在途数据被丢弃（表现为 exit=0 但 out 为空）。
    private var exitStatus: Int?
    private var settled = false
    private var settleTask: Scheduled<Void>?

    init(command: String, gate: PromiseGate) {
        self.command = command
        self.gate = gate
    }

    func handlerAdded(context: ChannelHandlerContext) {
        _ = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
    }

    func channelActive(context: ChannelHandlerContext) {
        let request = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false)
        context.triggerUserOutboundEvent(request, promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        let bytes: [UInt8]
        switch payload.data {
        case .byteBuffer(var buffer):
            bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        @unknown default:
            bytes = []
        }
        switch payload.type {
        case .channel: stdout.append(contentsOf: bytes)
        case .stdErr: stderr.append(contentsOf: bytes)
        default: break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            exitStatus = status.exitStatus
            // 退出码可能抢在数据前面到达：延迟兑现兜底，给出途数据留出落地时间。
            // 通道随后关闭 / 数据读完都会触发更早的 settle；这里只是保底。
            settleTask = context.eventLoop.scheduleTask(in: .milliseconds(400)) { [weak self] in
                self?.settle()
            }
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        settle()
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        settle()
    }

    /// 只兑现一次。用已收到的退出码（缺失则 -1）与当前累积的输出组装结果。
    private func settle() {
        guard !settled else { return }
        settled = true
        settleTask?.cancel()
        settleTask = nil
        gate.succeed(SSHExecResult(
            exitStatus: exitStatus ?? -1,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self)
        ))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(
            wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))),
            promise: promise
        )
    }
}
