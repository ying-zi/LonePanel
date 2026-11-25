import Foundation

/// Docker 业务命令层：全部通过共享 SSH 执行原生 docker CLI，服务端零依赖。
/// 所有命令经 SharedSSHConnection.run 自动按探测到的权限加 sudo 前缀。
/// 解析采用 `docker ... --format '{{json .}}'` 的逐行 JSON，稳定且不受 locale 影响。
@MainActor
final class DockerService {
    static let shared = DockerService()

    /// 专用连接：与全局终端物理隔离，终端保活重连不再打断 Docker 命令。
    private let connection = DockerSSHConnection.shared
    private let decoder: JSONDecoder = JSONDecoder()

    /// 页面级命令超时：容器多时 docker ps 可能稍慢，给 40 秒。
    private let listTimeout = 40
    /// stats 是锦上添花的资源快照，容器多时可能较慢；给较短超时，超时不影响容器列表本身。
    private let statsTimeout = 20

    // MARK: - 可用性探测

    /// 探测 Docker 是否可用：先看命令是否存在，再看服务端版本，最后判断权限。
    func checkAvailability() async -> DockerAvailability {
        guard await connection.ensureConnected() else {
            return .failed(connection.lastError ?? "连接失败")
        }
        // 1. 命令是否存在（普通用户无 docker 组时 docker 命令存在但访问 socket 会失败）
        let probe = await runRaw("command -v docker", timeout: 10)
        if probe.exit != 0 || probe.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .notInstalled
        }
        // 2. 服务端版本：能返回即说明 daemon 可访问、权限足够。
        let version = await runRaw("docker version --format '{{.Server.Version}}'", timeout: 15)
        if version.exit == 0 {
            let v = version.out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { return .available(version: v) }
        }
        // 3. 有输出但失败 → 多半是权限（不在 docker 组 / socket 权限）
        let combined = (version.out + version.err).lowercased()
        if combined.contains("permission denied") || combined.contains("permission") ||
           combined.contains("cannot connect") || combined.contains("dial unix") {
            return .permissionDenied
        }
        return .notInstalled
    }

    // MARK: - 列表数据

    /// 拉取容器 + 资源快照，合并为展示模型。两者并发执行，缩短等待。
    /// stats 超时或失败都不影响容器列表本身——资源只是锦上添花。
    func fetchContainers() async throws -> [DockerContainer] {
        async let psTask = run("docker ps -a --format '{{json .}}'", timeout: listTimeout)
        async let statsTask = run("docker stats --no-stream --format '{{json .}}'", timeout: statsTimeout)
        let ps = await psTask
        let stats = await statsTask

        if ps.exit != 0 {
            throw DockerError.commandFailed(message: firstError(ps, "读取容器列表失败"))
        }

        let rows = decodeLines(DockerPSRow.self, ps.out)
        // stats 按 ID 建索引，仅运行中容器有数据；失败时不影响容器列表本身。
        var statsByID: [String: DockerStatsRow] = [:]
        if stats.exit == 0 {
            for row in decodeLines(DockerStatsRow.self, stats.out) {
                statsByID[normalizeID(row.ID)] = row
            }
        }

        return rows.map { row in
            DockerContainer(row: row, stats: statsByID[normalizeID(row.ID)])
        }
        .sorted { lhs, rhs in
            // 运行中优先，再暂停，再停止；同级按名称。
            if lhs.state != rhs.state { return stateRank(lhs.state) < stateRank(rhs.state) }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// 拉取镜像列表。
    func fetchImages() async throws -> [DockerImage] {
        let result = await run("docker images --format '{{json .}}'", timeout: listTimeout)
        if result.exit != 0 {
            throw DockerError.commandFailed(message: firstError(result, "读取镜像列表失败"))
        }
        return decodeLines(DockerImageRow.self, result.out).map(DockerImage.init)
    }

    /// 拉取 Compose 项目。老版本无 `docker compose` 时返回空数组，不报错。
    func fetchComposeProjects() async throws -> [DockerComposeProject] {
        let result = await run("docker compose ls --format json", timeout: listTimeout)
        guard result.exit == 0 else { return [] }
        return decodeLines(DockerComposeRow.self, result.out).map(DockerComposeProject.init)
    }

    // MARK: - 容器操作

    func startContainer(_ id: String) async -> Result<Void, DockerError> {
        await mutate("docker start \(id)", success: "容器已启动")
    }

    func stopContainer(_ id: String) async -> Result<Void, DockerError> {
        await mutate("docker stop \(id)", success: "容器已停止")
    }

    func restartContainer(_ id: String) async -> Result<Void, DockerError> {
        await mutate("docker restart \(id)", success: "容器已重启")
    }

    func pauseContainer(_ id: String) async -> Result<Void, DockerError> {
        await mutate("docker pause \(id)", success: "容器已暂停")
    }

    func unpauseContainer(_ id: String) async -> Result<Void, DockerError> {
        await mutate("docker unpause \(id)", success: "容器已恢复")
    }

    func removeContainer(_ id: String) async -> Result<Void, DockerError> {
        await mutate("docker rm -f \(id)", success: "容器已删除")
    }

    // MARK: - 镜像 / Compose 操作

    func removeImage(_ id: String) async -> Result<Void, DockerError> {
        await mutate("docker rmi \(id)", success: "镜像已删除")
    }

    func composeAction(_ name: String, configFile: String, action: ComposeAction) async -> Result<Void, DockerError> {
        let fileArg = configFile.isEmpty ? "" : " -f \(ShellQuote.quote(configFile))"
        let command: String
        switch action {
        case .up: command = "docker compose\(fileArg) -p \(ShellQuote.quote(name)) up -d"
        case .down: command = "docker compose\(fileArg) -p \(ShellQuote.quote(name)) down"
        case .restart: command = "docker compose\(fileArg) -p \(ShellQuote.quote(name)) restart"
        }
        return await mutate(command, success: "操作已完成")
    }

    enum ComposeAction {
        case up, down, restart
    }

    // MARK: - 详情

    /// 读取容器 inspect 的原始 JSON 文本，详情页按需解析端口/挂载/网络/环境变量。
    func fetchInspect(containerID: String) async -> Result<String, DockerError> {
        let result = await run("docker inspect \(containerID)", timeout: 30)
        if result.exit != 0 {
            return .failure(.commandFailed(message: firstError(result, "读取容器详情失败")))
        }
        return .success(result.out)
    }

    // MARK: - 日志

    /// 读取容器日志（尾部 N 行）。日志页用定时器轮询实现自动刷新。
    func fetchLogs(containerID: String, tail: Int = 300) async -> Result<String, DockerError> {
        let result = await run("docker logs --tail \(tail) \(containerID)", timeout: 30)
        if result.exit != 0 {
            // docker logs 把部分信息写到 stderr，stderr 有内容也算有效日志。
            if !result.err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .success(result.err)
            }
            return .failure(.commandFailed(message: firstError(result, "读取日志失败")))
        }
        return .success(result.out)
    }

    // MARK: - 容器终端命令

    /// 构造容器终端的 exec 命令。优先 sh，失败由 UI 提示重试 bash。
    func execCommand(for container: DockerContainer, shell: String = "sh") -> String {
        "docker exec -it \(container.id) \(shell)"
    }

    // MARK: - 内部工具

    /// 带权限包装执行命令。连接层异常时自动重连并重试一次。
    private func run(_ command: String, timeout: Int) async -> (out: String, err: String, exit: Int) {
        await runWithReconnect(command, timeout: timeout, raw: false)
    }

    /// 不包装直接执行（仅探测阶段用），同样具备连接层重试。
    private func runRaw(_ command: String, timeout: Int) async -> (out: String, err: String, exit: Int) {
        await runWithReconnect(command, timeout: timeout, raw: true)
    }

    /// 统一的重连重试包装：
    /// - exit >= 0：命令确实在远端执行了（含 exit≠0 的命令失败），不重试，避免误操作。
    /// - exit < 0：连接层异常（通道被重连打断 / 超时 / 连接已关闭），强制重建连接后重试一次。
    private func runWithReconnect(_ command: String, timeout: Int, raw: Bool) async -> (out: String, err: String, exit: Int) {
        let first = await executeOnce(command, timeout: timeout, raw: raw)
        guard first.exit < 0 else { return first }
        guard await connection.ensureConnected(force: true) else { return first }
        return await executeOnce(command, timeout: timeout, raw: raw)
    }

    private func executeOnce(_ command: String, timeout: Int, raw: Bool) async -> (out: String, err: String, exit: Int) {
        do {
            let result = raw
                ? try await connection.runRaw(command, timeoutSeconds: timeout)
                : try await connection.run(command, timeoutSeconds: timeout)
            return (result.stdout, result.stderr, Int(result.exitStatus))
        } catch {
            return ("", SSHSession.describe(error), -1)
        }
    }

    private func mutate(_ command: String, success: String) async -> Result<Void, DockerError> {
        let result = await run(command, timeout: 30)
        if result.exit == 0 { return .success(()) }
        return .failure(.commandFailed(message: firstError(result, success)))
    }

    /// 取一条可读错误：优先 stderr，其次 stdout，最后兜底文案。
    private func firstError(_ result: (out: String, err: String, exit: Int), _ fallback: String) -> String {
        let err = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return err }
        return fallback
    }

    /// 逐行解析 JSON（忽略空行与解析失败的行），兼容日志中混入的告警。
    private func decodeLines<T: Decodable>(_ type: T.Type, _ text: String) -> [T] {
        text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
            return try? decoder.decode(T.self, from: data)
        }
    }

    /// Docker 的 container ID 在 ps 与 stats 中都是 64 位十六进制，统一小写去空白。
    private func normalizeID(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func stateRank(_ state: DockerContainerState) -> Int {
        switch state {
        case .running: return 0
        case .paused: return 1
        case .stopped: return 2
        }
    }
}

enum DockerError: LocalizedError {
    case commandFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message): return message
        }
    }
}
