import Foundation

/// 新建容器的完整规格。由创建表单逐项填写，交给 DockerService 拼装 `docker run`。
/// 纯数据模型——不含任何命令逻辑，便于单测与复用（如将来"从已有容器复制配置"）。
struct ContainerCreateSpec {
    // 基本
    var name: String = ""
    var image: String = ""
    /// 本地是否已有该镜像；false 时创建前先 docker pull。
    var pullImage: Bool = false

    // 端口映射：宿主端口 / 容器端口 / 协议
    struct PortMapping: Identifiable, Equatable {
        let id = UUID()
        var hostPort: String = ""
        var containerPort: String = ""
        var proto: String = "tcp"   // tcp / udp
    }
    var ports: [PortMapping] = []

    // 目录挂载：宿主路径 / 容器路径 / 读写模式
    struct Mount: Identifiable, Equatable {
        let id = UUID()
        var hostPath: String = ""      // 服务器绝对路径
        var containerPath: String = ""
        var readOnly: Bool = false
    }
    var mounts: [Mount] = []

    // 环境变量
    struct EnvVar: Identifiable, Equatable {
        let id = UUID()
        var key: String = ""
        var value: String = ""
    }
    var env: [EnvVar] = []

    // 网络与重启
    var network: String = "bridge"
    var restartPolicy: String = "unless-stopped"   // no / always / unless-stopped / on-failure

    // 资源限制（留空表示不限制）
    var memory: String = ""     // 如 512m / 1g
    var cpus: String = ""       // 如 0.5 / 2

    // 高级
    var hostname: String = ""
    var privileged: Bool = false
    var workdir: String = ""
    /// 覆盖镜像 ENTRYPOINT（留空不覆盖）。
    var entrypoint: String = ""
    /// 传给镜像的启动命令及参数（留空用镜像默认）。
    var command: String = ""

    // MARK: - 校验

    /// 校验所有字段，返回第一处错误文案；nil 表示合法。
    func validate() -> String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return L10n.t("Enter a container name") }
        guard Self.validContainerName(trimmedName) else {
            return L10n.t("Container name may contain only letters, digits, underscore, dot and hyphen, and cannot start with a special character")
        }
        guard !image.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return L10n.t("Enter an image name")
        }
        for p in ports where !p.hostPort.isEmpty || !p.containerPort.isEmpty {
            guard Self.validPort(p.hostPort), Self.validPort(p.containerPort) else {
                return L10n.f("Port must be a number between 1 and 65535 (%@)", String(describing: ("\(p.hostPort):\(p.containerPort)")))
            }
        }
        for m in mounts where !m.hostPath.isEmpty || !m.containerPath.isEmpty {
            guard m.hostPath.hasPrefix("/") else { return L10n.f("Host path must be absolute (start with /): %@", String(describing: (m.hostPath))) }
            guard m.containerPath.hasPrefix("/") else { return "Container path must be absolute (start with /): \(m.containerPath)" }
        }
        for e in env where !e.key.isEmpty || !e.value.isEmpty {
            guard Self.validEnvKey(e.key) else { return "Environment variable name may contain only letters, digits and underscore: \(e.key)" }
        }
        if !memory.isEmpty, Self.validMemory(memory) == false {
            return L10n.t("Memory must be a number plus unit (e.g. 512m / 1g)")
        }
        if !cpus.isEmpty, Double(cpus) == nil {
            return L10n.t("CPU must be a number (e.g. 0.5 / 2)")
        }
        return nil
    }

    static func validContainerName(_ raw: String) -> Bool {
        let pattern = "^[A-Za-z0-9][A-Za-z0-9_.-]*$"
        return NSPredicate(format: "SELF MATCHES %@", pattern).evaluate(with: raw)
    }

    static func validEnvKey(_ raw: String) -> Bool {
        let pattern = "^[A-Za-z_][A-Za-z0-9_]*$"
        return NSPredicate(format: "SELF MATCHES %@", pattern).evaluate(with: raw)
    }

    static func validPort(_ raw: String) -> Bool {
        guard let n = Int(raw), n >= 1, n <= 65535 else { return false }
        return true
    }

    static func validMemory(_ raw: String) -> Bool {
        let pattern = "^[0-9]+[kmgKMG]?$"
        return NSPredicate(format: "SELF MATCHES %@", pattern).evaluate(with: raw)
    }

    // MARK: - 反向填充（编辑现有容器）

    /// 从 `docker inspect` 解析结果反向填充编辑表单。
    /// 只还原 spec 能表达、且重建时必须保留的字段；spec 表达不了的（如 capAdd、设备映射、
    /// healthcheck、匿名卷等）由调用方生成 warnings 提示用户，避免"编辑后静默丢失"。
    /// 注意：memory / cpus / 挂载 readOnly 在 inspect 轻量解析里未取，故留空/默认，不臆造。
    static func from(inspect info: DockerInspectInfo) -> (spec: ContainerCreateSpec, warnings: [String]) {
        var spec = ContainerCreateSpec()
        var warnings: [String] = []

        spec.name = info.containerName
        spec.image = info.image
        spec.pullImage = false

        // 端口：inspect 的 host 形如 "8080" 或 "127.0.0.1:8080"，容器端形如 "80/tcp"。
        for binding in info.portBindings {
            let containerPort = binding.container.replacingOccurrences(of: "/tcp", with: "")
                                                .replacingOccurrences(of: "/udp", with: "")
            let proto = binding.container.hasSuffix("/udp") ? "udp" : "tcp"
            let hostPart = binding.host.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            // 只取端口数字部分（去掉可能的 HostIp 前缀）。
            let hostPort = hostPart.contains(":") ? String(hostPart.split(separator: ":").last ?? "") : hostPart
            guard !hostPort.isEmpty, !containerPort.isEmpty else { continue }
            spec.ports.append(PortMapping(hostPort: hostPort, containerPort: containerPort, proto: proto))
        }

        // 挂载：inspect 只解析了 source/destination，读写模式未取，按可写还原。
        for mount in info.mounts {
            guard mount.source.hasPrefix("/"), mount.destination.hasPrefix("/") else { continue }
            spec.mounts.append(Mount(hostPath: mount.source, containerPath: mount.destination, readOnly: false))
        }

        // 环境变量：inspect 是 "KEY=value" 数组，按第一个 = 拆分。
        for raw in info.env {
            guard let eq = raw.firstIndex(of: "=") else { continue }
            let key = String(raw[..<eq])
            let value = String(raw[raw.index(after: eq)...])
            guard !key.isEmpty else { continue }
            spec.env.append(EnvVar(key: key, value: value))
        }

        // 网络：优先 NetworkMode（host/none/bridge/自定义），回退 network。
        let network = info.networkMode.isEmpty ? info.network : info.networkMode
        spec.network = network.isEmpty ? "bridge" : network

        // 重启策略。
        spec.restartPolicy = info.restartPolicy.isEmpty ? "no" : info.restartPolicy

        // 高级：命令 / entrypoint 由数组拼回空格分隔字符串。
        spec.command = info.command.joined(separator: " ")
        spec.entrypoint = info.entrypoint.joined(separator: " ")
        spec.workdir = info.workingDir
        spec.hostname = info.hostname
        spec.privileged = info.privileged
        // user 与 spec 无对应字段，提示用户。
        if !info.user.isEmpty {
            warnings.append(L10n.f("Original container user (%@) cannot be restored in the form; it will use the image default.", String(describing: (info.user))))
        }
        if !info.capAdd.isEmpty {
            warnings.append(L10n.f("Capabilities added to the original container (%@) cannot be restored in the form.", String(describing: (info.capAdd.joined(separator: ", ")))))
        }
        if !info.healthcheck.isEmpty {
            warnings.append(L10n.t("The original container had a health check; it is not restored by the form."))
        }
        warnings.append(L10n.t("Anonymous volumes and data outside mounted paths are NOT preserved when the container is recreated."))

        return (spec, warnings)
    }
}
