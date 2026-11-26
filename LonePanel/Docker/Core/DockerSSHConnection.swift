import Foundation
import SwiftUI

/// Docker 业务专用 SSH 连接——与全局终端连接（SharedSSHConnection）物理隔离。
///
/// 背景：终端为保活会复用同一条 SSH 父连接，读循环意外断开时触发 forceReconnect，
/// performConnect 内部 `session?.close()` 会让父通道 channelInactive，进而
/// gateRegistry.failAll() 把所有在途命令一起打断。若 Docker 与终端共用该连接，
/// 容器列表（ps + stats 两条并发命令，暴露窗口大）几乎必被打断，镜像（单条快命令）
/// 则时好时坏。独立连接后两条链路互不干扰。
///
/// 生命周期跟当前服务器绑定：currentServer 变化或主动断开时重建。
@MainActor
final class DockerSSHConnection: ObservableObject {
    static let shared = DockerSSHConnection()

    @Published private(set) var isConnected = false
    @Published private(set) var lastError: String?

    private var session: SSHSession?
    private var privilege: RemotePrivilege = .none
    private var connectTask: Task<Bool, Never>?
    private var connectedServerID: UUID?

    /// 建立或复用连接。并发调用合并为一个任务；force 时强制重建父连接。
    @discardableResult
    func ensureConnected(force: Bool = false) async -> Bool {
        guard let info = ServerSession.shared.currentServer else {
            lastError = L10n.t("Please add and select a server in Settings → My Servers first")
            return false
        }
        if !force, isConnected, connectedServerID == info.id, session != nil { return true }
        if let connectTask { return await connectTask.value }

        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            return await self.performConnect(info: info)
        }
        connectTask = task
        let ok = await task.value
        connectTask = nil
        return ok
    }

    private func performConnect(info: ServerConnectionInfo) async -> Bool {
        isConnected = false
        lastError = nil
        do {
            let secret = try KeychainStore.load(info.credentialKey)
            let credential: SSHAuthCredential
            switch info.authKind {
            case .password: credential = .password(secret)
            case .privateKey: credential = .privateKey(secret)
            }
            let newSession = try await SSHSession(
                host: info.host,
                port: info.port,
                username: info.username,
                credential: credential
            )
            let newPrivilege = await Self.detectPrivilege(on: newSession, serverID: info.id)
            session?.close()
            session = newSession
            privilege = newPrivilege
            connectedServerID = info.id
            isConnected = true
            return true
        } catch {
            session?.close()
            session = nil
            isConnected = false
            lastError = SSHSession.describe(error)
            return false
        }
    }

    /// 权限探测：root → 免密 sudo → 普通用户。结果按服务器持久化，与终端共用缓存键。
    private static func detectPrivilege(on session: SSHSession, serverID: UUID) async -> RemotePrivilege {
        let cacheKey = "shared.privilege.\(serverID.uuidString)"
        if let cached = UserDefaults.standard.string(forKey: cacheKey),
           let hit = RemotePrivilege(rawValue: cached) {
            return hit
        }
        var result: RemotePrivilege = .none
        if let uid = try? await session.execute("id -u", timeoutSeconds: 8),
           uid.exitStatus == 0,
           uid.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "0" {
            result = .root
        } else if let probe = try? await session.execute("sudo -n true", timeoutSeconds: 8),
                  probe.exitStatus == 0 {
            result = .sudo
        }
        UserDefaults.standard.set(result.rawValue, forKey: cacheKey)
        return result
    }

    /// 执行命令，按权限自动加 sudo 前缀。
    func run(_ command: String, timeoutSeconds: Int = 30) async throws -> SSHExecResult {
        guard let session else { throw SSHConnectionError.closedUnexpectedly }
        let wrapped: String
        switch privilege {
        case .sudo: wrapped = "sudo -n \(command)"
        default: wrapped = command
        }
        return try await session.execute(wrapped, timeoutSeconds: timeoutSeconds)
    }

    /// 不包装直接执行（仅探测阶段用）。
    func runRaw(_ command: String, timeoutSeconds: Int = 30) async throws -> SSHExecResult {
        guard let session else { throw SSHConnectionError.closedUnexpectedly }
        return try await session.execute(command, timeoutSeconds: timeoutSeconds)
    }

    // MARK: - 交互式 shell（供容器终端复用本条已验证连接）

    /// 在 Docker 这条连接上开带 PTY 的 exec 通道，执行 `docker exec -it ... sh`。
    /// 容器终端复用本连接，避免另起 SharedSSHConnection 时可能从未建立/已被断开的问题。
    func openExecShell(command: String) async throws -> SSHShell {
        guard let session else { throw SSHConnectionError.closedUnexpectedly }
        return try await session.openExec(command: command)
    }

    func openShell() async throws -> SSHShell {
        guard let session else { throw SSHConnectionError.closedUnexpectedly }
        return try await session.openShell()
    }

    func closeShell() {
        // Docker 连接的 exec 通道是一次性的，由 SSHShell 自身 close；此处无需缓存清理。
    }

    func disconnect() {
        session?.close()
        session = nil
        isConnected = false
        privilege = .none
        connectedServerID = nil
    }
}
