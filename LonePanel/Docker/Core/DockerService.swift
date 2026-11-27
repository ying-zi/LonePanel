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
    /// 注意：探测命令同样走 `run`（带 sudo 包装）。之前用 runRaw 不带 sudo 会在
    /// 「需要 sudo 才能访问 Docker」的服务器上把可用性误判为 notInstalled/permissionDenied，
    /// 导致容器页被门槛挡住、根本不去拉数据——而镜像页无门槛所以能显示，症状极不一致。
    func checkAvailability() async -> DockerAvailability {
        guard await connection.ensureConnected() else {
            return .failed(connection.lastError ?? L10n.t("Connection Failed"))
        }
        // 用「docker version」一条命令同时验证：命令存在 + daemon 可访问 + 权限足够。
        // 注意：必须是 docker 外部命令（可用 sudo 包装），不能用 command -v（shell 内建，加 sudo 会报 command not found）。
        // 版本号为空也算可用（老版本 Docker 可能不支持该 format），真正校验交给 list 命令。
        let version = await run("docker version --format '{{.Server.Version}}'", timeout: 15)
        if version.exit == 0 {
            let v = version.out.trimmingCharacters(in: .whitespacesAndNewlines)
            return .available(version: v.isEmpty ? L10n.t("Installed") : v)
        }
        // 失败 → 依据错误文本区分「没装」与「无权访问」
        let combined = (version.out + version.err).lowercased()
        if combined.contains("permission denied") || combined.contains("permission") ||
           combined.contains("cannot connect") || combined.contains("dial unix") ||
           combined.contains("not found") || combined.contains("not recognized") {
            return .permissionDenied
        }
        return .notInstalled
    }

    // MARK: - 列表数据

    /// 拉取容器 + 资源快照，合并为展示模型。两者并发执行，缩短等待。
    /// stats 超时或失败都不影响容器列表本身——资源只是锦上添花。
    func fetchContainers() async throws -> [DockerContainer] {
        async let psTask = runNonEmpty("docker ps -a --format '{{json .}}'", timeout: listTimeout)
        async let statsTask = run("docker stats --no-stream --format '{{json .}}'", timeout: statsTimeout)
        let ps = await psTask
        let stats = await statsTask

        if ps.exit != 0 {
            throw DockerError.commandFailed(message: firstError(ps, L10n.t("Failed to load containers")))
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
        let result = await runNonEmpty("docker images --format '{{json .}}'", timeout: listTimeout)
        if result.exit != 0 {
            throw DockerError.commandFailed(message: firstError(result, L10n.t("Failed to load images")))
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
        await mutate("docker start \(id)", success: L10n.t("Container started"))
    }

    func stopContainer(_ id: String) async -> Result<Void, DockerError> {
        await mutate("docker stop \(id)", success: L10n.t("Container stopped"))
    }

    func restartContainer(_ id: String) async -> Result<Void, DockerError> {
        await mutate("docker restart \(id)", success: L10n.t("Container restarted"))
    }

    func pauseContainer(_ id: String) async -> Result<Void, DockerError> {
        await mutate("docker pause \(id)", success: L10n.t("Container paused"))
    }

    func unpauseContainer(_ id: String) async -> Result<Void, DockerError> {
        await mutate("docker unpause \(id)", success: L10n.t("Container resumed"))
    }

    func removeContainer(_ id: String) async -> Result<Void, DockerError> {
        await mutate("docker rm -f \(id)", success: L10n.t("Container removed"))
    }

    /// 强制停止容器（docker kill），用于容器无响应、正常 stop 卡住的场景。
    func killContainer(_ id: String) async -> Result<Void, DockerError> {
        await mutate("docker kill \(id)", success: L10n.t("Container force-stopped"))
    }

    // MARK: - 创建容器（对标 1Panel）

    /// 拉取镜像。progress 由 docker 自己写到 stderr，这里只判定结果。
    func pullImage(_ reference: String) async -> Result<Void, DockerError> {
        let ref = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ref.isEmpty else { return .failure(.commandFailed(message: L10n.t("Image name cannot be empty"))) }
        // pull 可能较慢（大镜像），给 180 秒；超时不用 mutate 的默认 30 秒。
        let result = await run("docker pull \(ShellQuote.quote(ref))", timeout: 180)
        if result.exit == 0 { return .success(()) }
        return .failure(.commandFailed(message: firstError(result, L10n.t("Failed to pull image"))))
    }

    /// 拉取网络列表（名字），供创建表单选择。bridge/host/none 固定项由 UI 补，这里只取自定义网络。
    func fetchNetworks() async -> [String] {
        let result = await run("docker network ls --format '{{.Name}}'", timeout: 20)
        guard result.exit == 0 else { return [] }
        return result.out.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - 网络管理（对标 1Panel：列表 / 创建 / 删除）

    /// 拉取完整网络列表（含 driver/scope 等），用于网络管理页。
    func fetchNetworkList() async throws -> [DockerNetwork] {
        let result = await runNonEmpty("docker network ls --format '{{json .}}'", timeout: listTimeout)
        if result.exit != 0 {
            throw DockerError.commandFailed(message: firstError(result, L10n.t("Failed to load networks")))
        }
        return decodeLines(DockerNetworkRow.self, result.out).map(DockerNetwork.init)
            .sorted { lhs, rhs in
                // 自定义网络优先，系统网络（bridge/host/none）置后；同级按名称。
                if lhs.isSystem != rhs.isSystem { return !lhs.isSystem && rhs.isSystem }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    /// 创建网络：docker network create [--driver d] [--subnet s] [--gateway g] [--internal] [--ipv6] name。
    /// 所有外部输入经 ShellQuote.quote；名称做字符集校验即时反馈。
    /// 注：参数名用 isInternal 而非 internal——后者是 Swift 保留关键字，会编译失败。
    func createNetwork(name: String, driver: String, subnet: String, gateway: String, isInternal: Bool, ipv6: Bool) async -> Result<Void, DockerError> {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validResourceName(n) else {
            return .failure(.commandFailed(message: L10n.t("Invalid network name")))
        }
        var parts = ["docker", "network", "create"]
        let d = driver.trimmingCharacters(in: .whitespacesAndNewlines)
        if !d.isEmpty { parts += ["--driver", ShellQuote.quote(d)] }
        let s = subnet.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { parts += ["--subnet", ShellQuote.quote(s)] }
        let g = gateway.trimmingCharacters(in: .whitespacesAndNewlines)
        if !g.isEmpty { parts += ["--gateway", ShellQuote.quote(g)] }
        if isInternal { parts.append("--internal") }
        if ipv6 { parts.append("--ipv6") }
        parts.append(ShellQuote.quote(n))
        return await mutate(parts.joined(separator: " "), success: L10n.f("Network created: %@", n))
    }

    /// 删除网络：docker network rm <name>。被容器占用的网络 docker 会拒绝，错误原样透出。
    func removeNetwork(name: String) async -> Result<Void, DockerError> {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else {
            return .failure(.commandFailed(message: L10n.t("Invalid network name")))
        }
        return await mutate("docker network rm \(ShellQuote.quote(n))", success: L10n.f("Network removed: %@", n))
    }

    // MARK: - 存储卷管理（对标 1Panel：列表 / 创建 / 删除）

    /// 拉取完整存储卷列表。
    func fetchVolumeList() async throws -> [DockerVolume] {
        let result = await runNonEmpty("docker volume ls --format '{{json .}}'", timeout: listTimeout)
        if result.exit != 0 {
            throw DockerError.commandFailed(message: firstError(result, L10n.t("Failed to load volumes")))
        }
        return decodeLines(DockerVolumeRow.self, result.out).map(DockerVolume.init)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// 创建存储卷：docker volume create [--driver d] name。
    func createVolume(name: String, driver: String) async -> Result<Void, DockerError> {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // 卷名允许留空（docker 会随机生成），但一旦填写就校验字符集。
        if !n.isEmpty, !Self.validResourceName(n) {
            return .failure(.commandFailed(message: L10n.t("Invalid volume name")))
        }
        var parts = ["docker", "volume", "create"]
        let d = driver.trimmingCharacters(in: .whitespacesAndNewlines)
        if !d.isEmpty { parts += ["--driver", ShellQuote.quote(d)] }
        if !n.isEmpty { parts.append(ShellQuote.quote(n)) }
        return await mutate(parts.joined(separator: " "), success: n.isEmpty ? L10n.t("Volume created") : L10n.f("Volume created: %@", n))
    }

    /// 删除存储卷：docker volume rm <name>。被容器引用的卷 docker 会拒绝，错误原样透出。
    func removeVolume(name: String) async -> Result<Void, DockerError> {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else {
            return .failure(.commandFailed(message: L10n.t("Invalid volume name")))
        }
        return await mutate("docker volume rm \(ShellQuote.quote(n))", success: L10n.f("Volume removed: %@", n))
    }

    /// Docker 资源名（网络/卷）校验：允许字母数字与 _ . -，长度 1...255，不含空格与路径分隔符。
    /// ShellQuote 已防注入，这里主要给用户即时格式反馈。
    static func validResourceName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 255 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// 按规格创建并启动容器（docker run -d），返回新容器 ID。
    /// 命令构造纪律：所有外部输入经 ShellQuote.quote；端口/数值在 Spec 层已校验。
    func createContainer(_ spec: ContainerCreateSpec) async -> Result<String, DockerError> {
        if let error = spec.validate() {
            return .failure(.commandFailed(message: error))
        }
        // 需要时先拉镜像；失败直接返回，不继续 run。
        if spec.pullImage {
            switch await pullImage(spec.image) {
            case .failure(let e): return .failure(e)
            case .success: break
            }
        }

        let command = Self.buildRunCommand(spec)
        let result = await run(command, timeout: 60)
        guard result.exit == 0 else {
            return .failure(.commandFailed(message: firstError(result, L10n.t("Failed to create container"))))
        }
        let id = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(id)
    }

    /// 命令行创建容器（对标 1Panel「命令行创建」）：用户粘贴一条完整 docker run 命令，原样执行。
    /// 安全纪律：
    /// - 只允许单条命令，禁止换行/分号/管道/反引号/`$()` 等拼接，避免借「创建容器」之名执行任意脚本。
    /// - 必须以 `docker run` 开头（允许前导 sudo），杜绝 docker exec/system prune 等越权命令。
    /// - 命令本身由用户逐字提供并二次确认，不再做 ShellQuote（否则整条命令会被当作单个参数）；
    ///   这也正是「表单创建」与「命令行创建」的区别：前者逐字段 quote，后者由用户对原文负责。
    /// - 仍走 run()（带 epoch 校验 + 重连重试），不绕过连接层。
    func createContainerFromCommand(_ raw: String) async -> Result<String, DockerError> {
        let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            return .failure(.commandFailed(message: L10n.t("Command cannot be empty")))
        }
        // 禁止换行与 shell 元字符拼接：单条命令才允许，防止一次粘贴执行多条语句。
        let dangerous = ["\n", "\r", ";", "|", "`", "$(", "&&", "||", ">", "<"]
        for token in dangerous where command.contains(token) {
            return .failure(.commandFailed(message: L10n.t("Only a single docker run command is allowed")))
        }
        // 剥离前导 sudo（连接层已按权限自动包装），只校验剩余部分。
        var body = command
        if body.lowercased().hasPrefix("sudo ") {
            body = String(body.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard body.lowercased().hasPrefix("docker run ") || body.lowercased() == "docker run" else {
            return .failure(.commandFailed(message: L10n.t("Command must start with docker run")))
        }
        let result = await run(command, timeout: 90)
        guard result.exit == 0 else {
            return .failure(.commandFailed(message: firstError(result, L10n.t("Failed to create container from command"))))
        }
        let id = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            return .failure(.commandFailed(message: L10n.t("Docker returned no container id")))
        }
        AppEventBus.shared.emit(.containersChanged)
        return .success(id)
    }

    /// 构造 `docker run -d ...` 命令。独立静态方法便于审查与复用（如命令预览）。
    static func buildRunCommand(_ spec: ContainerCreateSpec) -> String {
        var parts: [String] = ["docker", "run", "-d"]

        parts += ["--name", ShellQuote.quote(spec.name.trimmingCharacters(in: .whitespacesAndNewlines))]

        // 网络
        let network = spec.network.trimmingCharacters(in: .whitespacesAndNewlines)
        if !network.isEmpty { parts += ["--network", ShellQuote.quote(network)] }

        // 重启策略：on-failure 不带次数，交由用户填 "on-failure:5" 这种完整值。
        let restart = spec.restartPolicy.trimmingCharacters(in: .whitespacesAndNewlines)
        if !restart.isEmpty, restart != "no" { parts += ["--restart", ShellQuote.quote(restart)] }

        // 端口映射
        for p in spec.ports where ContainerCreateSpec.validPort(p.hostPort) && ContainerCreateSpec.validPort(p.containerPort) {
            let proto = p.proto == "udp" ? "/udp" : ""
            parts += ["-p", ShellQuote.quote("\(p.hostPort):\(p.containerPort)\(proto)")]
        }

        // 目录挂载
        for m in spec.mounts where m.hostPath.hasPrefix("/") && m.containerPath.hasPrefix("/") {
            let mode = m.readOnly ? ":ro" : ":rw"
            parts += ["-v", ShellQuote.quote("\(m.hostPath):\(m.containerPath)\(mode)")]
        }

        // 环境变量
        for e in spec.env where ContainerCreateSpec.validEnvKey(e.key) {
            parts += ["-e", ShellQuote.quote("\(e.key)=\(e.value)")]
        }

        // 资源限制
        let memory = spec.memory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !memory.isEmpty, ContainerCreateSpec.validMemory(memory) {
            parts += ["--memory", ShellQuote.quote(memory)]
        }
        let cpus = spec.cpus.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cpus.isEmpty, Double(cpus) != nil {
            parts += ["--cpus", ShellQuote.quote(cpus)]
        }

        // 高级
        let hostname = spec.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hostname.isEmpty { parts += ["--hostname", ShellQuote.quote(hostname)] }
        if spec.privileged { parts.append("--privileged") }
        let workdir = spec.workdir.trimmingCharacters(in: .whitespacesAndNewlines)
        if !workdir.isEmpty { parts += ["-w", ShellQuote.quote(workdir)] }
        let entrypoint = spec.entrypoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !entrypoint.isEmpty { parts += ["--entrypoint", ShellQuote.quote(entrypoint)] }

        // 镜像（末尾位置参数）
        parts.append(ShellQuote.quote(spec.image.trimmingCharacters(in: .whitespacesAndNewlines)))

        // 启动命令及参数：按空格切分，逐段转义，避免注入。
        let command = spec.command.trimmingCharacters(in: .whitespacesAndNewlines)
        if !command.isEmpty {
            parts += command.split(whereSeparator: { $0 == " " || $0 == "\n" })
                .map { ShellQuote.quote(String($0)) }
        }

        return parts.joined(separator: " ")
    }

    // MARK: - 镜像 / Compose 操作

    func removeImage(_ id: String) async -> Result<Void, DockerError> {
        await mutate("docker rmi \(id)", success: L10n.t("Image removed"))
    }

    // MARK: - 镜像管理增强（对标 1Panel：拉取 / 打标签 / 导入 / 导出）

    /// 给镜像打标签：docker tag <source> <repo>:<tag>。
    /// 引用与镜像 ID 均经 ShellQuote.quote，防止注入。
    func tagImage(sourceID: String, repository: String, tag: String) async -> Result<Void, DockerError> {
        let repo = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        let tg = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty else {
            return .failure(.commandFailed(message: L10n.t("Repository cannot be empty")))
        }
        let reference = tg.isEmpty ? repo : "\(repo):\(tg)"
        guard Self.validImageReference(reference) else {
            return .failure(.commandFailed(message: L10n.t("Invalid image name or tag")))
        }
        let command = "docker tag \(ShellQuote.quote(sourceID)) \(ShellQuote.quote(reference))"
        return await mutate(command, success: L10n.f("Tagged as %@", reference))
    }

    /// 导出镜像到服务器目录：docker save -o <dir>/<file> <image>。
    /// 返回实际写入的服务器路径供 UI 展示。大镜像耗时，给 300 秒。
    func exportImage(imageID: String, directory: String, filename: String) async -> Result<String, DockerError> {
        let dir = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty, dir.hasPrefix("/") else {
            return .failure(.commandFailed(message: L10n.t("Please choose a destination directory")))
        }
        var name = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "image.tar" }
        if !name.hasSuffix(".tar") && !name.hasSuffix(".tar.gz") { name += ".tar" }
        // 文件名不允许含路径分隔符，避免逃出所选目录。
        name = name.replacingOccurrences(of: "/", with: "_")
        let fullPath = "\(dir.hasSuffix("/") ? dir : dir + "/")\(name)"
        let command = "docker save -o \(ShellQuote.quote(fullPath)) \(ShellQuote.quote(imageID))"
        let result = await run(command, timeout: 300)
        if result.exit == 0 { return .success(fullPath) }
        return .failure(.commandFailed(message: firstError(result, L10n.t("Failed to export image"))))
    }

    /// 从服务器上的 tar 文件导入镜像：docker load -i <path>。
    func importImage(tarPath: String) async -> Result<Void, DockerError> {
        let path = tarPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path.hasPrefix("/") else {
            return .failure(.commandFailed(message: L10n.t("Please enter a valid file path")))
        }
        let command = "docker load -i \(ShellQuote.quote(path))"
        let result = await run(command, timeout: 300)
        if result.exit == 0 {
            AppEventBus.shared.emit(.containersChanged)
            return .success(())
        }
        return .failure(.commandFailed(message: firstError(result, L10n.t("Failed to import image"))))
    }

    /// 镜像名/tag 的宽松校验：只允许字母数字与 . _ - / : ，且不含空格。
    /// ShellQuote 已防注入，这里主要给用户即时格式反馈。
    static func validImageReference(_ ref: String) -> Bool {
        guard !ref.isEmpty, ref.count <= 512 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/:")
        return ref.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    func composeAction(_ name: String, configFile: String, action: ComposeAction) async -> Result<Void, DockerError> {
        let fileArg = configFile.isEmpty ? "" : " -f \(ShellQuote.quote(configFile))"
        let command: String
        switch action {
        case .up: command = "docker compose\(fileArg) -p \(ShellQuote.quote(name)) up -d"
        case .down: command = "docker compose\(fileArg) -p \(ShellQuote.quote(name)) down"
        case .restart: command = "docker compose\(fileArg) -p \(ShellQuote.quote(name)) restart"
        }
        return await mutate(command, success: L10n.t("Done"))
    }

    enum ComposeAction {
        case up, down, restart
    }

    // MARK: - 编排模板（对标 1Panel：模板 → 写 yml → 部署）

    /// 把编排 yml 写到服务器指定目录的 <项目名>.yml 文件。
    /// 内容走 base64：yml 里含引号、`$`、换行等，直接拼 heredoc 有注入与转义风险；
    /// base64 只含 A-Za-z0-9+/=，经 quote 后绝对安全，服务端 `base64 -d` 还原。
    /// 目录与文件名都做校验 + quote，防止逃出所选目录。
    func saveComposeFile(directory: String, projectName: String, yaml: String) async -> Result<String, DockerError> {
        let dir = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty, dir.hasPrefix("/") else {
            return .failure(.commandFailed(message: L10n.t("Please choose a destination directory")))
        }
        let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validResourceName(name) else {
            return .failure(.commandFailed(message: L10n.t("Invalid project name")))
        }
        guard !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.commandFailed(message: L10n.t("Compose content cannot be empty")))
        }
        let base64 = Data(yaml.utf8).base64EncodedString()
        let fullPath = "\(dir.hasSuffix("/") ? dir : dir + "/")docker-compose.\(name).yml"
        // 先确保目录存在，再写文件；两条命令用 && 串联，任一步失败即止。
        let command = "mkdir -p \(ShellQuote.quote(dir)) && printf '%s' \(ShellQuote.quote(base64)) | base64 -d > \(ShellQuote.quote(fullPath))"
        let result = await run(command, timeout: 30)
        guard result.exit == 0 else {
            return .failure(.commandFailed(message: firstError(result, L10n.t("Failed to save compose file"))))
        }
        return .success(fullPath)
    }

    /// 部署编排：docker compose -f <path> -p <project> up -d。
    /// 成功广播 containersChanged（会新建容器），供其它模块订阅刷新。
    func deployCompose(path: String, project: String) async -> Result<Void, DockerError> {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = project.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, p.hasPrefix("/"), Self.validResourceName(name) else {
            return .failure(.commandFailed(message: L10n.t("Invalid compose file or project name")))
        }
        let command = "docker compose -f \(ShellQuote.quote(p)) -p \(ShellQuote.quote(name)) up -d"
        let result = await run(command, timeout: 180)
        guard result.exit == 0 else {
            return .failure(.commandFailed(message: firstError(result, L10n.t("Failed to deploy compose"))))
        }
        AppEventBus.shared.emit(.containersChanged)
        return .success(())
    }

    // MARK: - 详情

    /// 读取容器 inspect 的原始 JSON 文本，详情页按需解析端口/挂载/网络/环境变量。
    func fetchInspect(containerID: String) async -> Result<String, DockerError> {
        let result = await run("docker inspect \(containerID)", timeout: 30)
        if result.exit != 0 {
            return .failure(.commandFailed(message: firstError(result, L10n.t("Failed to load container details"))))
        }
        return .success(result.out)
    }

    // MARK: - 日志

    /// 读取容器日志（尾部 N 行）。日志页用定时器轮询实现自动刷新。
    func fetchLogs(containerID: String, tail: Int = 300) async -> Result<String, DockerError> {
        let result = await run("docker logs --tail \(tail) \(containerID)", timeout: 30)
        return parseLogs(result)
    }

    /// 读取指定时间范围以来的日志（1Panel 同款：最近 10 分钟 / 1 小时 / 1 天）。
    func fetchLogs(containerID: String, since: String) async -> Result<String, DockerError> {
        let result = await run("docker logs --since \(since) \(containerID)", timeout: 30)
        return parseLogs(result)
    }

    /// 读取全部日志（用于下载导出）。
    func fetchAllLogs(containerID: String) async -> Result<String, DockerError> {
        let result = await run("docker logs \(containerID)", timeout: 40)
        return parseLogs(result)
    }

    private func parseLogs(_ result: (out: String, err: String, exit: Int)) -> Result<String, DockerError> {
        let err = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
        let out = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        // 关键：命令失败时，docker 把 "Error: No such container" 等错误信息写进 stderr。
        // 旧逻辑只要 combined 非空就当成功日志返回，UI 又只在 success 时赋值 →
        // 错误被当日志、或永久沉默（界面空白）。先识别失败特征，再决定是否为日志。
        if result.exit != 0 {
            let message = firstError(result, L10n.t("Failed to load logs"))
            return .failure(.commandFailed(message: message))
        }
        // exit=0 但 stderr 以典型错误前缀开头（某些 docker 版本错误仍返回 0）——同样判失败。
        let lower = err.lowercased()
        if lower.hasPrefix("error:") || lower.hasPrefix("error response from daemon") {
            return .failure(.commandFailed(message: err))
        }
        // docker logs 把容器 stderr 输出也并进来，正常日志可能落在 err，故两者合并。
        let combined = result.out + (result.out.isEmpty ? "" : "\n") + result.err
        if !combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .success(combined)
        }
        return .success("")
    }

    // MARK: - 进程

    /// 读取容器内进程列表（docker top），供详情页「进程」区展示。
    func fetchProcesses(containerID: String) async -> Result<[DockerProcess], DockerError> {
        let result = await run("docker top \(containerID) -eo pid,user,args", timeout: 20)
        if result.exit != 0 {
            return .failure(.commandFailed(message: firstError(result, L10n.t("Failed to load process list"))))
        }
        return .success(DockerProcess.parse(result.out))
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

    /// 列表类命令专用：底层偶发「exit=0 但 stdout 为空」（退出码抢在数据前到达），
    /// 遇到空输出时最多重试 2 次。真实空列表（确实没有容器/镜像）重试后仍为空，结果不变。
    private func runNonEmpty(_ command: String, timeout: Int) async -> (out: String, err: String, exit: Int) {
        var result = await run(command, timeout: timeout)
        var attempts = 0
        while result.exit == 0 &&
              result.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
              attempts < 2 {
            attempts += 1
            result = await run(command, timeout: timeout)
        }
        return result
    }

    private func executeOnce(_ command: String, timeout: Int, raw: Bool) async -> (out: String, err: String, exit: Int) {
        let result: (out: String, err: String, exit: Int)
        do {
            let exec = raw
                ? try await connection.runRaw(command, timeoutSeconds: timeout)
                : try await connection.run(command, timeoutSeconds: timeout)
            result = (exec.stdout, exec.stderr, Int(exec.exitStatus))
        } catch {
            result = ("", SSHSession.describe(error), -1)
        }
        DockerDiagnostics.shared.record(command: command, exit: result.exit, out: result.out, err: result.err)
        return result
    }

    private func mutate(_ command: String, success: String) async -> Result<Void, DockerError> {
        let result = await run(command, timeout: 30)
        if result.exit == 0 {
            // 所有容器/镜像/Compose 变更都经此；一处广播，供网站联动等模块订阅刷新。
            AppEventBus.shared.emit(.containersChanged)
            return .success(())
        }
        // 失败路径绝不能用 success 文案兜底：stderr/stdout 皆空时 firstError 会返回 success，
        // 造成"操作失败却提示已启动/已删除"。改用明确的失败文案。
        return .failure(.commandFailed(message: firstError(result, L10n.t("Operation failed. Docker returned no error details."))))
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
