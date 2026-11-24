import Foundation
import NIOCore
import NIOSSH

/// 交互式 SSH Shell 通道：在已认证连接上分配 PTY 并启动远端 shell。
/// 用于 APP 内置终端——用户可粘贴安装命令、输 sudo 密码等，走真实 SSH 交互会话。
final class SSHShell {
    private let channel: Channel
    private let inbox: ByteInbox
    private let lock = NSLock()
    private var closed = false

    init(channel: Channel, inbox: ByteInbox) {
        self.channel = channel
        self.inbox = inbox
    }

    /// 向远端 shell 写入原始字节（键盘输入 / 命令）。
    func send(_ bytes: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        channel.writeAndFlush(buffer, promise: nil)
    }

    /// 读取远端 shell 输出；无数据时挂起等待。
    func receive() async throws -> [UInt8] {
        try await inbox.take()
    }

    /// 通知远端窗口尺寸变化（字符宽高）。
    func resize(columns: Int, rows: Int) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        let event = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: columns,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        channel.triggerUserOutboundEvent(event, promise: nil)
    }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()
        _ = channel.close(promise: nil)
        inbox.fail(SSHConnectionError.closedUnexpectedly)
    }

    deinit { close() }
}

extension SSHSession {
    /// 开一个交互式 shell 子通道：先 PTY 请求，成功后发 Shell 请求。
    func openShell(columns: Int = 80, rows: Int = 24) async throws -> SSHShell {
        let ssh: NIOSSHHandler = try await withCheckedThrowingContinuation { continuation in
            channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
                switch result {
                case .success(let handler): continuation.resume(returning: handler)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }

        let ready = channel.eventLoop.makePromise(of: Void.self)
        let inbox = ByteInbox()
        let childPromise = channel.eventLoop.makePromise(of: Channel.self)

        ssh.createChannel(childPromise) { child, type in
            guard type == .session else {
                return child.eventLoop.makeFailedFuture(SSHConnectionError.invalidChannelType)
            }
            return child.eventLoop.makeCompletedFuture {
                let handler = ShellHandler(ready: ready, inbox: inbox, columns: columns, rows: rows)
                try child.pipeline.syncOperations.addHandler(handler)
            }
        }

        let child = try await childPromise.futureResult.get()
        try await ready.futureResult.get()
        return SSHShell(channel: child, inbox: inbox)
    }
}

/// 发起 PTY/Shell 请求、双向转发字节的 NIO handler。
private final class ShellHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = Never
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let ready: EventLoopPromise<Void>
    private let inbox: ByteInbox
    private let columns: Int
    private let rows: Int
    private var ptyRequested = false
    private var shellRequested = false
    private var resolved = false

    init(ready: EventLoopPromise<Void>, inbox: ByteInbox, columns: Int, rows: Int) {
        self.ready = ready
        self.inbox = inbox
        self.columns = columns
        self.rows = rows
    }

    func channelActive(context: ChannelHandlerContext) {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: columns,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        context.triggerUserOutboundEvent(pty, promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = payload.data else { return }
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        inbox.append(bytes)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelSuccessEvent {
            if !ptyRequested {
                ptyRequested = true
                let shell = SSHChannelRequestEvent.ShellRequest(wantReply: true)
                context.triggerUserOutboundEvent(shell, promise: nil)
            } else if !shellRequested {
                shellRequested = true
                if !resolved { resolved = true; ready.succeed(()) }
            }
        } else if event is ChannelFailureEvent {
            if !resolved {
                resolved = true
                ready.fail(SSHConnectionError.authenticationUnsupported)
            }
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(
            wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))),
            promise: promise
        )
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !resolved { resolved = true; ready.fail(error) }
        inbox.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        inbox.fail(SSHConnectionError.closedUnexpectedly)
        context.fireChannelInactive()
    }
}
