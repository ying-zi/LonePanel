import Foundation
import SwiftUI

/// 命令执行权限档位。面向通用服务器，绝不假设用户一定是 root。
enum RemotePrivilege: String {
    case root   // id -u = 0，命令直接执行
    case sudo   // 非 root，但 sudo -n 免密可用，命令自动加前缀
    case none   // 普通用户，无 root 也无免密 sudo（命令可能权限不足，界面给引导）
}

/// 全局共享的 SSH 连接：供 Docker / 内置终端等模块复用同一条已认证连接。
/// 文件模块保持自己独立的 SFTP 连接，不受此处改动影响（已完工模块不做回归风险改造）。
@MainActor
final class SharedSSHConnection: ObservableObject {
    static let shared = SharedSSHConnection()

    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var connectionFailed = false
    @Published private(set) var lastError: String?
    @Published private(set) var privilege: RemotePrivilege?
    @Published private(set) var connectedServerID: UUID?

    private var session: SSHSession?
    private var shell: SSHShell?
    private var connectTask: Task<Bool, Never>?

    var serverName: String { ServerSession.shared.currentServer?.name ?? "服务器" }

    /// 建立（或复用）到当前服务器的连接。并发调用合并为同一任务，避免重复建连。
    @discardableResult
    func ensureConnected(force: Bool = false) async -> Bool {
        guard let info = ServerSession.shared.currentServer else {
            lastError = "请先到「设置 → 我的服务器」添加并选择一个服务器"
            connectionFailed = true
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
        isConnecting = true
        connectionFailed = false
        lastError = nil
        defer { isConnecting = false }
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
            // 提交连接前先探测权限，避免出现"连上了但不知道用什么身份执行"的中间态。
            let newPrivilege = await Self.detectPrivilege(on: newSession, serverID: info.id)
            session?.close()
            session = newSession
            shell = nil
            privilege = newPrivilege
            connectedServerID = info.id
            isConnected = true
            return true
        } catch {
            session?.close()
            session = nil
            shell = nil
            isConnected = false
            connectionFailed = true
            lastError = SSHSession.describe(error)
            return false
        }
    }

    /// 探测执行权限：root → 免密 sudo → 普通用户。结果按服务器持久化，避免每次重探。
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

    /// 重新探测权限（设置里可手动触发，应对权限变更）。
    func redetectPrivilege() async {
        guard let session, let serverID = connectedServerID else { return }
        UserDefaults.standard.removeObject(forKey: "shared.privilege.\(serverID.uuidString)")
        privilege = await Self.detectPrivilege(on: session, serverID: serverID)
    }

    /// 执行命令，按探测到的权限自动加 sudo 前缀。失败信息翻译为中文。
    func run(_ command: String, timeoutSeconds: Int = 30) async throws -> SSHExecResult {
        guard let session else { throw SSHConnectionError.closedUnexpectedly }
        let wrapped: String
        switch privilege {
        case .sudo: wrapped = "sudo -n \(command)"
        default: wrapped = command
        }
        return try await session.execute(wrapped, timeoutSeconds: timeoutSeconds)
    }

    /// 不包装直接执行，供权限探测或用户终端等场景使用。
    func runRaw(_ command: String, timeoutSeconds: Int = 30) async throws -> SSHExecResult {
        guard let session else { throw SSHConnectionError.closedUnexpectedly }
        return try await session.execute(command, timeoutSeconds: timeoutSeconds)
    }

    /// 打开（或复用）全局交互 shell。切 Tab 不销毁会话。
    func openShell() async throws -> SSHShell {
        if let shell { return shell }
        guard let session else { throw SSHConnectionError.closedUnexpectedly }
        let newShell = try await session.openShell()
        shell = newShell
        return newShell
    }

    /// 开一条独立的交互式 exec 通道（带 PTY 执行指定命令），供 Docker 容器终端使用。
    /// 每次调用都是新通道、不复用全局 shell——容器终端与用户终端互不干扰。
    func openExecShell(command: String) async throws -> SSHShell {
        guard let session else { throw SSHConnectionError.closedUnexpectedly }
        return try await session.openExec(command: command)
    }

    func closeShell() {
        shell?.close()
        shell = nil
    }

    func disconnect() {
        closeShell()
        session?.close()
        session = nil
        isConnected = false
        connectedServerID = nil
        privilege = nil
    }
}

/// shell 引号转义：把任意字符串包成安全的单引号参数。
enum ShellQuote {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
