import Foundation
import NIOCore
import NIOSSH

/// SSH 子通道的原始字节流管道。根 Core 只负责 SSH 通道与传输，
/// 具体协议（如 SFTP）由功能模块在此之上实现。
final class SSHSubsystemChannel {
    private let channel: Channel
    private let inbox: ByteInbox

    init(channel: Channel, inbox: ByteInbox) {
        self.channel = channel
        self.inbox = inbox
    }

    /// 向子通道写入原始字节。线程安全。
    func send(_ bytes: [UInt8]) {
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        channel.writeAndFlush(buffer, promise: nil)
    }

    /// 从子通道读取下一批字节；无数据时会挂起等待。
    func receive() async throws -> [UInt8] {
        try await inbox.take()
    }

    func close() {
        _ = channel.close(promise: nil)
    }
}

extension SSHSession {
    /// 在已认证的 SSH 连接上开启一个 subsystem 子通道（如 "sftp"）。
    func openSubsystem(_ name: String) async throws -> SSHSubsystemChannel {
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
                let handler = SubsystemHandler(name: name, ready: ready, inbox: inbox)
                try child.pipeline.syncOperations.addHandler(handler)
            }
        }

        let child = try await childPromise.futureResult.get()
        try await ready.futureResult.get()
        return SSHSubsystemChannel(channel: child, inbox: inbox)
    }
}

// MARK: - 线程安全字节收件箱

/// 把 NIO event loop 上收到的字节，安全地交给 Swift 并发中的读取方。
final class ByteInbox {
    private let lock = NSLock()
    private var buffer: [UInt8] = []
    private var waiter: CheckedContinuation<[UInt8], Error>?
    private var failure: Error?

    func append(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: bytes)
            return
        }
        buffer.append(contentsOf: bytes)
        lock.unlock()
    }

    func fail(_ error: Error) {
        lock.lock()
        let waiter = self.waiter
        self.waiter = nil
        self.failure = error
        lock.unlock()
        waiter?.resume(throwing: error)
    }

    func take() async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !buffer.isEmpty {
                let bytes = buffer
                buffer.removeAll(keepingCapacity: true)
                lock.unlock()
                continuation.resume(returning: bytes)
                return
            }
            if let failure {
                lock.unlock()
                continuation.resume(throwing: failure)
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }
}

// MARK: - 子通道 NIO handler

/// 负责发起 subsystem 请求、接收子通道数据、把字节写入收件箱。
private final class SubsystemHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = Never
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let name: String
    private let ready: EventLoopPromise<Void>
    private let inbox: ByteInbox
    private var resolved = false

    init(name: String, ready: EventLoopPromise<Void>, inbox: ByteInbox) {
        self.name = name
        self.ready = ready
        self.inbox = inbox
    }

    func channelActive(context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.SubsystemRequest(subsystem: name, wantReply: true),
            promise: nil
        )
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
            if !resolved { resolved = true; ready.succeed(()) }
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
