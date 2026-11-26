import Foundation

/// 基于 SSHSubsystemChannel 的 SFTP v3 客户端。
/// 只依赖根 Core 的 SSH 传输能力；不认识任何服务器业务对象。
final class SFTPClient {
    private let transport: SSHSubsystemChannel
    /// 强持有连接，确保通道与 event loop 组在会话期间存活。
    private let session: SSHSession

    private let lock = NSLock()
    private var nextRequestID: UInt32 = 1
    private var pending: [UInt32: Pending] = [:]
    private var initContinuation: CheckedContinuation<SFTPPacket, Error>?
    private var buffer: [UInt8] = []
    private var readerTask: Task<Void, Never>?
    private var closed = false

    private final class Pending {
        let continuation: CheckedContinuation<SFTPPacket, Error>
        let timeout: DispatchWorkItem
        init(continuation: CheckedContinuation<SFTPPacket, Error>, timeout: DispatchWorkItem) {
            self.continuation = continuation
            self.timeout = timeout
        }
    }

    private init(transport: SSHSubsystemChannel, session: SSHSession) {
        self.transport = transport
        self.session = session
    }

    /// 在当前 SSH 连接上打开 sftp subsystem 并完成握手。
    static func connect(session: SSHSession) async throws -> SFTPClient {
        let transport = try await session.openSubsystem("sftp")
        let client = SFTPClient(transport: transport, session: session)
        client.startReading()
        try await client.handshake()
        return client
    }

    deinit {
        close()
    }

    func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        let all = Array(pending.values)
        let initWaiter = initContinuation
        pending.removeAll()
        initContinuation = nil
        lock.unlock()

        readerTask?.cancel()
        all.forEach { $0.timeout.cancel() }
        all.forEach { $0.continuation.resume(throwing: SFTPError.notConnected) }
        initWaiter?.resume(throwing: SFTPError.notConnected)
        transport.close()
    }

    // MARK: - 握手与读循环

    private func handshake() async throws {
        let packet = SFTPPacket(type: SFTPMessage.initialize, payload: SFTPWire.be32(3))
        // VERSION 响应由 dispatch 通过 initContinuation 兑现；这里只等待握手完成。
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SFTPPacket, Error>) in
            lock.lock()
            initContinuation = continuation
            lock.unlock()
            transport.send(packet.framed)
        }
    }

    private func startReading() {
        readerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let chunk = try await transport.receive()
                    ingest(chunk)
                } catch {
                    failAll(error)
                    return
                }
            }
        }
    }

    private func ingest(_ chunk: [UInt8]) {
        lock.lock()
        buffer.append(contentsOf: chunk)
        var packets: [SFTPPacket] = []
        while buffer.count >= 4 {
            let bodyLength = Int((try? SFTPWire.uint32(buffer, at: 0)) ?? 0)
            guard bodyLength > 0 else { buffer.removeAll(); break }
            let total = 4 + bodyLength
            guard buffer.count >= total else { break }
            let body = Array(buffer[4..<total])
            buffer.removeFirst(total)
            guard let type = body.first else { continue }
            packets.append(SFTPPacket(type: type, payload: Array(body.dropFirst())))
        }
        lock.unlock()

        for packet in packets { dispatch(packet) }
    }

    private func dispatch(_ packet: SFTPPacket) {
        if packet.type == SFTPMessage.version {
            lock.lock()
            let waiter = initContinuation
            initContinuation = nil
            lock.unlock()
            waiter?.resume(returning: packet)
            return
        }

        guard let requestID = try? SFTPWire.uint32(packet.payload, at: 0) else { return }
        lock.lock()
        let entry = pending.removeValue(forKey: requestID)
        lock.unlock()
        entry?.timeout.cancel()
        entry?.continuation.resume(returning: packet)
    }

    private func failAll(_ error: Error) {
        lock.lock()
        let all = Array(pending.values)
        let initWaiter = initContinuation
        pending.removeAll()
        initContinuation = nil
        lock.unlock()
        all.forEach { $0.timeout.cancel() }
        all.forEach { $0.continuation.resume(throwing: error) }
        initWaiter?.resume(throwing: error)
    }

    // MARK: - 请求/响应

    private func request(type: UInt8, payload: [UInt8] = [], timeoutSeconds: Double = 25) async throws -> SFTPPacket {
        lock.lock()
        let id = nextRequestID
        nextRequestID &+= 1
        lock.unlock()

        var body = PayloadWriter()
        body.uint32(id)
        body.raw(payload)
        let packet = SFTPPacket(type: type, payload: body.bytes)

        return try await withCheckedThrowingContinuation { continuation in
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let entry = self.pending.removeValue(forKey: id)
                self.lock.unlock()
                entry?.continuation.resume(throwing: SFTPError.malformed(L10n.t("Server response timed out")))
            }
            lock.lock()
            if closed {
                lock.unlock()
                continuation.resume(throwing: SFTPError.notConnected)
                return
            }
            pending[id] = Pending(continuation: continuation, timeout: workItem)
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: workItem)
            transport.send(packet.framed)
        }
    }

    /// 期望一个 STATUS(OK) 响应，否则抛出人话错误。
    private func expectOK(_ packet: SFTPPacket) throws {
        guard packet.type == SFTPMessage.status else {
            throw SFTPError.malformed(L10n.t("Expected status response"))
        }
        var reader = PayloadReader(packet.payload)
        _ = try reader.uint32() // request id
        let code = try reader.uint32()
        let message = try reader.string()
        if code != SFTPStatusCode.ok {
            throw SFTPError.status(code: code, message: message)
        }
    }

    // MARK: - 公开操作

    /// 取服务器的真实（绝对）路径，用于定位默认访问目录的起点。
    func canonicalize(_ path: String = ".") async throws -> String {
        var payload = PayloadWriter()
        payload.string(path)
        let response = try await request(type: SFTPMessage.realpath, payload: payload.bytes)
        guard response.type == SFTPMessage.name else { try expectOK(response); return path }
        var reader = PayloadReader(response.payload)
        _ = try reader.uint32() // request id
        let count = try reader.uint32()
        guard count > 0 else { return path }
        let resolved = try reader.string() // filename 即真实路径
        return resolved
    }

    /// 规范化路径：把 "/" 拼接成合法绝对路径。
    func joined(_ base: String, _ name: String) -> String {
        if base == "/" { return "/" + name }
        return base + "/" + name
    }

    func listDirectory(_ path: String) async throws -> [RemoteFile] {
        var open = PayloadWriter()
        open.string(path)
        open.uint32(SFTPOpenFlag.read)
        open.raw(FileAttributes().encoded)
        let opened = try await request(type: SFTPMessage.opendir, payload: open.bytes)
        guard opened.type == SFTPMessage.handle else {
            try expectOK(opened)
            return []
        }
        var handleReader = PayloadReader(opened.payload)
        _ = try handleReader.uint32()
        let handle = try handleReader.data()

        defer { closeHandle(handle) }

        var result: [RemoteFile] = []
        while true {
            var read = PayloadWriter()
            read.blob(handle)
            let response = try await request(type: SFTPMessage.readdir, payload: read.bytes)

            if response.type == SFTPMessage.status {
                var statusReader = PayloadReader(response.payload)
                _ = try statusReader.uint32()
                let code = try statusReader.uint32()
                let message = try statusReader.string()
                if code == SFTPStatusCode.eof { break }
                throw SFTPError.status(code: code, message: message)
            }
            guard response.type == SFTPMessage.name else {
                throw SFTPError.malformed(L10n.t("Expected directory listing response"))
            }

            var reader = PayloadReader(response.payload)
            _ = try reader.uint32() // request id
            let count = try reader.uint32()
            for _ in 0..<count {
                let name = try reader.string()
                _ = try reader.string() // longname
                let attrs = try reader.attributes()
                let mode = attrs.permissions ?? 0
                let fileType = mode & 0o170000
                let isDir = fileType == 0o040000
                let isLink = fileType == 0o120000
                if name == "." || name == ".." { continue }
                result.append(RemoteFile(
                    name: name,
                    path: joined(path, name),
                    isDirectory: isDir,
                    isSymlink: isLink,
                    size: Int64(clamping: attrs.size ?? 0),
                    modified: attrs.mtime.map { Date(timeIntervalSince1970: Double($0)) },
                    permissions: mode,
                    uid: attrs.uid,
                    gid: attrs.gid
                ))
            }
        }
        return result
    }

    func makeDirectory(_ path: String) async throws {
        var payload = PayloadWriter()
        payload.string(path)
        payload.raw(FileAttributes().encoded)
        try expectOK(try await request(type: SFTPMessage.mkdir, payload: payload.bytes))
    }

    func removeDirectory(_ path: String) async throws {
        var payload = PayloadWriter()
        payload.string(path)
        try expectOK(try await request(type: SFTPMessage.rmdir, payload: payload.bytes))
    }

    func removeFile(_ path: String) async throws {
        var payload = PayloadWriter()
        payload.string(path)
        try expectOK(try await request(type: SFTPMessage.remove, payload: payload.bytes))
    }

    func rename(from oldPath: String, to newPath: String) async throws {
        var payload = PayloadWriter()
        payload.string(oldPath)
        payload.string(newPath)
        try expectOK(try await request(type: SFTPMessage.rename, payload: payload.bytes))
    }

    /// 纯 SFTP 移动：优先 rename；失败时回退为「复制 + 删除」，兼容跨设备/目标已存在。
    /// 全程不依赖远端 exec 通道。
    func move(_ file: RemoteFile, toDirectory target: String) async throws {
        let destination = joined(target, file.name)
        let parent = (file.path as NSString).deletingLastPathComponent
        if (parent as NSString).standardizingPath == (target as NSString).standardizingPath { return }
        if file.path == destination { return }
        do {
            try await rename(from: file.path, to: destination)
        } catch {
            // rename 在某些服务端会拒绝跨文件系统或同名覆盖，回退到复制 + 删除。
            // 安全铁律：只有"确实完成了逐字节复制"才允许删除源。对软链/含软链的目录，
            // copyItem 无法保真复制（返回 false），此时绝不删源——直接抛错让上层
            // FileBrowserModel.transfer 回退到 shell `mv`（mv 对软链是原子的、无丢失）。
            let copiedFaithfully = try await copyItem(file, to: destination)
            guard copiedFaithfully else { throw SFTPError.symlinkCopyUnsupported }
            if file.isDirectory { try await removeDirectory(file.path) }
            else { try await removeFile(file.path) }
        }
    }

    /// 纯 SFTP 复制：文件走 read+write；目录递归创建并复制子项。不依赖远端 exec 通道。
    /// onProgress 汇报「本条 copy 已写入的总字节数」，供 UI 显示大文件/多文件进度。
    func copy(_ file: RemoteFile, toDirectory target: String,
              onProgress: ((Int64) -> Void)? = nil) async throws {
        let counter = ByteCounter()
        _ = try await copyItem(file, to: joined(target, file.name)) { delta in
            counter.value += delta
            onProgress?(counter.value)
        }
    }

    /// 路径是否存在（STAT 返回 ATTRS 即存在，返回 STATUS 即不存在）。
    private func pathExists(_ path: String) async -> Bool {
        var payload = PayloadWriter()
        payload.string(path)
        guard let response = try? await request(type: SFTPMessage.stat, payload: payload.bytes) else {
            return false
        }
        return response.type == SFTPMessage.attrs
    }

    /// 递归复制单个条目。健壮性处理：
    /// - 目标目录已存在时直接合并，不再 mkdir（MKDIR 对已存在目录会报错）；
    /// - 跳过符号链接（readFile 一个指向目录的软链会失败并中断整个复制）；
    /// - 复制到自身或自身子目录时跳过，避免 read+write 同一文件造成损坏/死循环。
    /// - Returns: 是否"保真"复制（false = 遇到软链被跳过，内容不完整）。
    ///   返回 false 时调用方（尤其 move 的回退）绝不能删除源，否则数据不可逆丢失。
    private func copyItem(_ file: RemoteFile, to dest: String,
                          onBytes: ((Int64) -> Void)? = nil) async throws -> Bool {
        let src = (file.path as NSString).standardizingPath
        let dst = (dest as NSString).standardizingPath
        // 复制到自身或自身子目录：视为"无需复制"，对 move 而言等价于已就位。
        if dst == src || dst.hasPrefix(src + "/") { return true }
        // 软链无法通过 readFile 保真复制（指向目录会失败，指向文件会变成实体副本）。
        // 返回 false 通知调用方：复制不完整，禁止删除源。
        if file.isSymlink { return false }
        if file.isDirectory {
            if !(await pathExists(dst)) { try await makeDirectory(dst) }
            let children = try await listDirectory(file.path)
            var faithful = true
            for child in children {
                let childOK = try await copyItem(child, to: joined(dest, child.name), onBytes: onBytes)
                faithful = faithful && childOK
            }
            return faithful
        } else {
            let data = try await readFile(file.path)
            try await writeFile(dest, data: data, onBytes: onBytes)
            return true
        }
    }

    /// 在同一条已认证连接上执行远端命令。
    /// 主要用于文件夹统计、删除/移动等需要 shell 的场景；超时可按需放宽。
    func execute(_ command: String, timeoutSeconds: Int = 20) async throws -> SSHExecResult {
        try await session.execute(command, timeoutSeconds: timeoutSeconds)
    }

    /// 读取文件。expectedSize 与 onProgress 配合，向 UI 汇报 0...1 的下载进度。
    func readFile(_ path: String, expectedSize: Int64 = 0,
                  onProgress: ((Double) -> Void)? = nil) async throws -> Data {
        var open = PayloadWriter()
        open.string(path)
        open.uint32(SFTPOpenFlag.read)
        open.raw(FileAttributes().encoded)
        let opened = try await request(type: SFTPMessage.open, payload: open.bytes)
        guard opened.type == SFTPMessage.handle else {
            try expectOK(opened)
            return Data()
        }
        var handleReader = PayloadReader(opened.payload)
        _ = try handleReader.uint32()
        let handle = try handleReader.data()

        defer { closeHandle(handle) }

        var data = Data()
        var offset: UInt64 = 0
        let chunkSize: UInt32 = 32 * 1024
        while true {
            var read = PayloadWriter()
            read.blob(handle)
            read.uint64(offset)
            read.uint32(chunkSize)
            let response = try await request(type: SFTPMessage.read, payload: read.bytes)

            if response.type == SFTPMessage.status {
                var statusReader = PayloadReader(response.payload)
                _ = try statusReader.uint32()
                let code = try statusReader.uint32()
                if code == SFTPStatusCode.eof { break }
                let message = try statusReader.string()
                throw SFTPError.status(code: code, message: message)
            }
            guard response.type == SFTPMessage.data else {
                throw SFTPError.malformed(L10n.t("Expected file data response"))
            }
            var reader = PayloadReader(response.payload)
            _ = try reader.uint32()
            let chunk = try reader.data()
            if chunk.isEmpty { break }
            data.append(contentsOf: chunk)
            offset += UInt64(chunk.count)
            if let onProgress, expectedSize > 0 {
                onProgress(min(1, Double(data.count) / Double(expectedSize)))
            }
        }
        onProgress?(1)
        return data
    }

    func writeFile(_ path: String, data: Data,
                   onBytes: ((Int64) -> Void)? = nil) async throws {
        var open = PayloadWriter()
        open.string(path)
        open.uint32(SFTPOpenFlag.write | SFTPOpenFlag.trunc | SFTPOpenFlag.creat)
        open.raw(FileAttributes().encoded)
        let opened = try await request(type: SFTPMessage.open, payload: open.bytes)
        guard opened.type == SFTPMessage.handle else {
            try expectOK(opened)
            return
        }
        var handleReader = PayloadReader(opened.payload)
        _ = try handleReader.uint32()
        let handle = try handleReader.data()

        defer { closeHandle(handle) }

        let chunkSize = 32 * 1024
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let length = min(chunkSize, bytes.count - offset)
            let chunk = Array(bytes[offset..<(offset + length)])
            var write = PayloadWriter()
            write.blob(handle)
            write.uint64(UInt64(offset))
            write.blob(chunk) // 4 字节长度 + 原始字节，可承载二进制
            try expectOK(try await request(type: SFTPMessage.write, payload: write.bytes))
            offset += length
            onBytes?(Int64(length))
        }
    }

    /// fire-and-forget 关闭句柄：响应回来时按 request id 在 dispatch 中找不到 pending，自然丢弃。
    private func closeHandle(_ handle: [UInt8]) {
        lock.lock()
        let id = nextRequestID
        nextRequestID &+= 1
        lock.unlock()
        var body = PayloadWriter()
        body.uint32(id)
        body.blob(handle)
        transport.send(SFTPPacket(type: SFTPMessage.close, payload: body.bytes).framed)
    }
}

/// 复制进度的字节累加器。作为引用类型被闭包捕获，规避值类型在并发闭包中的捕获限制。
private final class ByteCounter {
    var value: Int64 = 0
}
