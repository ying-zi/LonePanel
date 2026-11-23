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
        case .invalidPort: return "端口必须在 1–65535 之间"
        case .invalidChannelType: return "服务器拒绝了会话通道"
        case .invalidPrivateKey(let text): return text
        case .authenticationUnsupported:
            return "服务器不接受所选认证方式，请检查服务端是否开启私钥/密码认证"
        case .authenticationFailed: return "认证失败：用户名或凭证不正确"
        case .timedOut: return "连接超时，请检查地址、端口与网络连通性"
        case .closedUnexpectedly: return "连接被服务器关闭，通常是认证失败或主机拒绝"
        case .underlying(let text): return text
        }
    }
}

/// 根 Core/SSH 的连接封装：建立 SSH 连接、认证、执行远端命令。
/// 具体业务模块通过 ServerSession.currentServer 取得连接参数后使用它，不自行管理通道。
final class SSHSession {
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    private let gateBox: GateBox

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
        let gateBox = GateBox()
        self.gateBox = gateBox

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
                    try sync.addHandler(ParentErrorHandler(gateBox: gateBox))
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
    func execute(_ command: String, timeoutSeconds: Int = 20) async throws -> SSHExecResult {
        let promise = group.next().makePromise(of: SSHExecResult.self)
        let gate = PromiseGate(promise)
        gateBox.set(gate)
        defer { gateBox.set(nil) }

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

    static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription {
            return text
        }
        return String(describing: error)
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
        return "连接成功：SSH 握手与认证通过，命令通道可用"
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

/// 父通道的错误转发到当前命令的 Promise。
private final class GateBox {
    private let lock = NSLock()
    private var current: PromiseGate?

    func set(_ gate: PromiseGate?) {
        lock.lock(); current = gate; lock.unlock()
    }

    func fail(_ error: Error) {
        lock.lock(); let gate = current; lock.unlock()
        gate?.fail(error)
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

private final class ParentErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private let gateBox: GateBox
    init(gateBox: GateBox) { self.gateBox = gateBox }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        gateBox.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        gateBox.fail(SSHConnectionError.closedUnexpectedly)
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
        guard case .byteBuffer(var buffer) = payload.data else { return }
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        switch payload.type {
        case .channel: stdout.append(contentsOf: bytes)
        case .stdErr: stderr.append(contentsOf: bytes)
        default: break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            gate.succeed(SSHExecResult(
                exitStatus: status.exitStatus,
                stdout: String(decoding: stdout, as: UTF8.self),
                stderr: String(decoding: stderr, as: UTF8.self)
            ))
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        gate.fail(SSHConnectionError.closedUnexpectedly)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(
            wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))),
            promise: promise
        )
    }
}
