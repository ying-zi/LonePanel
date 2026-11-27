import Foundation

/// 容器运行状态。对应 docker ps 的 Status 字段，用于筛选、色条与智能切换。
enum DockerContainerState: String {
    case running
    case paused
    case stopped

    /// 从 `docker ps --format` 的 Status 文本判断状态。
    /// Docker 输出示例：Up 3 days / Up 2 minutes (Paused) / Exited (0) 5 hours ago / Created
    static func from(_ status: String) -> DockerContainerState {
        let s = status.lowercased()
        if s.contains("paused") { return .paused }
        if s.hasPrefix("up") { return .running }
        return .stopped
    }
}

/// docker ps -a --format '{{json .}}' 单行解析结果。
/// 只声明需要的字段——Codable 默认忽略其余字段，兼容不同 Docker 版本。
struct DockerPSRow: Decodable {
    let ID: String
    let Names: String
    let Image: String
    let Command: String?
    let Created: String?
    let Ports: String?
    let Status: String
    let Size: String?
    let Labels: String?
}

/// docker stats --no-stream --format '{{json .}}' 单行解析结果（仅运行中容器有）。
struct DockerStatsRow: Decodable {
    let ID: String
    let Name: String?
    let CPUPerc: String?
    let MemUsage: String?
    let MemPerc: String?
    let NetIO: String?
    let BlockIO: String?
    let PIDs: String?
}

/// docker images --format '{{json .}}' 单行解析结果。
struct DockerImageRow: Decodable {
    let ID: String
    let Repository: String?
    let Tag: String?
    let CreatedSince: String?
    let Size: String?
    let Containers: String?
}

/// docker compose ls --format json 解析结果。
struct DockerComposeRow: Decodable {
    let Name: String
    let Status: String?
    let ConfigFiles: String?
}

/// 资源用量，已换算成便于展示的数值（GB / 百分比）。
struct DockerResourceUsage {
    /// CPU 百分比 0...100（可能超过 100，多核）
    var cpuPercent: Double = 0
    /// 已用内存（GB）
    var memUsedGB: Double = 0
    /// 内存上限（GB）
    var memLimitGB: Double = 0
    /// 内存百分比 0...100
    var memPercent: Double = 0
    /// 网络 IO 原始文本，如 "1.13MB / 8.43MB"（下行 / 上行）
    var netIO: String = ""
    /// 磁盘 IO 原始文本，如 "35GB / 80.5GB"
    var blockIO: String = ""
    /// 进程数
    var pids: String = ""

    var hasData: Bool { memLimitGB > 0 || cpuPercent > 0 }

    /// 展示用内存绝对值，带单位，如 "1.8 GB / 4 GB"。
    var memoryText: String {
        guard memLimitGB > 0 else { return "—" }
        return "\(formatGB(memUsedGB)) GB / \(formatGB(memLimitGB)) GB"
    }

    private func formatGB(_ v: Double) -> String {
        if v >= 10 { return String(format: "%.0f", v) }
        if v >= 1 { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }

    /// 解析 Docker 的 MemUsage 文本，如 "446.3MiB / 1.943GiB"。
    static func parseMemUsage(_ text: String?) -> (used: Double, limit: Double) {
        guard let text else { return (0, 0) }
        let parts = text.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return (0, 0) }
        return (parseGB(parts[0]), parseGB(parts[1]))
    }

    /// 把带单位的 Docker 容量文本换算成 GB。支持 B/KiB/MiB/GiB/TiB 与十进制单位。
    static func parseGB(_ raw: String) -> Double {
        let s = raw.trimmingCharacters(in: .whitespaces).uppercased()
        let unitKeywords = ["TIB", "GIB", "MIB", "KIB", "TB", "GB", "MB", "KB", "B"]
        var numberPart = s
        var multiplier = 1.0
        for unit in unitKeywords {
            if s.hasSuffix(unit) {
                numberPart = String(s.dropLast(unit.count))
                switch unit {
                case "TIB", "TB": multiplier = 1024
                case "GIB", "GB": multiplier = 1
                case "MIB", "MB": multiplier = 1.0 / 1024
                case "KIB", "KB": multiplier = 1.0 / (1024 * 1024)
                default: multiplier = 1.0 / (1024 * 1024 * 1024)
                }
                break
            }
        }
        let number = Double(numberPart.trimmingCharacters(in: .whitespaces)) ?? 0
        return number * multiplier
    }

    /// 解析 "45.12%" 为 45.12。
    static func parsePercent(_ text: String?) -> Double {
        guard let text else { return 0 }
        return Double(text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) ?? 0
    }
}

/// 合并了基础信息与实时资源的容器展示模型。
/// 遵循 Hashable 以便作为 NavigationStack 的导航目标值。
struct DockerContainer: Identifiable, Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: DockerContainer, rhs: DockerContainer) -> Bool { lhs.id == rhs.id }

    let id: String
    let name: String
    let image: String
    let command: String
    let created: String
    let portsText: String
    let statusText: String
    let size: String
    let labels: String
    let state: DockerContainerState
    var usage: DockerResourceUsage

    init(row: DockerPSRow, stats: DockerStatsRow? = nil) {
        self.id = row.ID
        self.name = row.Names.split(separator: ",").first.map(String.init) ?? row.ID
        self.image = row.Image
        self.command = row.Command ?? ""
        self.created = row.Created ?? ""
        self.portsText = row.Ports ?? ""
        self.statusText = row.Status
        self.size = row.Size ?? ""
        self.labels = row.Labels ?? ""
        self.state = DockerContainerState.from(row.Status)

        var usage = DockerResourceUsage()
        if let stats {
            usage.cpuPercent = DockerResourceUsage.parsePercent(stats.CPUPerc)
            usage.memPercent = DockerResourceUsage.parsePercent(stats.MemPerc)
            let mem = DockerResourceUsage.parseMemUsage(stats.MemUsage)
            usage.memUsedGB = mem.used
            usage.memLimitGB = mem.limit
            usage.netIO = stats.NetIO ?? ""
            usage.blockIO = stats.BlockIO ?? ""
            usage.pids = stats.PIDs ?? ""
        }
        self.usage = usage
    }

    /// 端口映射首项，如 "0.0.0.0:80 → 80/tcp"。空则返回 nil。
    var primaryPort: String? {
        let trimmed = portsText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(separator: ",").first.map(String.init)?.trimmingCharacters(in: .whitespaces)
    }

    /// 其余端口数量（用于卡片 "+N"）。
    var extraPortCount: Int {
        let trimmed = portsText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return 0 }
        return max(0, trimmed.split(separator: ",").count - 1)
    }
}

/// 镜像展示模型。
struct DockerImage: Identifiable {
    let id: String
    let repository: String
    let tag: String
    let createdSince: String
    let size: String
    let containers: String

    var fullName: String {
        if tag.isEmpty { return repository }
        return "\(repository):\(tag)"
    }

    init(row: DockerImageRow) {
        // 处理 <none> 镜像：仓库名为 <none> 时用 ID 前 12 位占位，便于识别。
        var repo = row.Repository ?? "<none>"
        if repo == "<none>" { repo = "\(row.ID.prefix(12))" }
        self.id = row.ID
        self.repository = repo
        self.tag = row.Tag ?? ""
        self.createdSince = row.CreatedSince ?? ""
        self.size = row.Size ?? ""
        self.containers = row.Containers ?? ""
    }
}

/// docker network ls --format '{{json .}}' 单行解析结果。
/// 字段按 Docker 官方 network ls 输出声明，Codable 忽略其余字段兼容版本差异。
struct DockerNetworkRow: Decodable {
    let ID: String?
    let Name: String
    let Driver: String?
    let Scope: String?
    let Internal: String?
    let Attachable: String?
    let IPv6: String?
}

/// docker volume ls --format '{{json .}}' 单行解析结果。
/// 老版本 Docker 的 volume ls 无 Size 字段，故全部可选。
struct DockerVolumeRow: Decodable {
    let Driver: String?
    let Name: String
    let Size: String?
    let Labels: String?
}

/// 网络展示模型。
struct DockerNetwork: Identifiable, Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: DockerNetwork, rhs: DockerNetwork) -> Bool { lhs.id == rhs.id }

    let id: String
    let name: String
    let driver: String
    let scope: String
    let isInternal: Bool
    let attachable: Bool
    let ipv6: Bool

    init(row: DockerNetworkRow) {
        self.id = row.ID ?? row.Name
        self.name = row.Name
        self.driver = row.Driver ?? ""
        self.scope = row.Scope ?? ""
        self.isInternal = (row.Internal ?? "").lowercased() == "true"
        self.attachable = (row.Attachable ?? "").lowercased() == "true"
        self.ipv6 = (row.IPv6 ?? "").lowercased() == "true"
    }

    /// Docker 内置的 bridge/host/none 三个网络不可删除。
    var isSystem: Bool { name == "bridge" || name == "host" || name == "none" }
}

/// 存储卷展示模型。
struct DockerVolume: Identifiable, Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: DockerVolume, rhs: DockerVolume) -> Bool { lhs.id == rhs.id }

    let id: String
    let name: String
    let driver: String
    let size: String
    let labels: String

    init(row: DockerVolumeRow) {
        self.name = row.Name
        self.id = row.Name
        self.driver = row.Driver ?? ""
        self.size = row.Size ?? ""
        self.labels = row.Labels ?? ""
    }
}

/// Compose 项目展示模型。
struct DockerComposeProject: Identifiable {
    let name: String
    let status: String
    let configFiles: String

    var id: String { name }

    init(row: DockerComposeRow) {
        self.name = row.Name
        self.status = row.Status ?? ""
        self.configFiles = row.ConfigFiles ?? ""
    }
}

/// 权限探测结果：告知用户当前连接能否使用 Docker。
enum DockerAvailability {
    case available(version: String)
    case notInstalled
    case permissionDenied
    case failed(String)
}

// MARK: - Inspect 详情解析

/// 从 `docker inspect` JSON 中抽取的详情，供详情页展示。
struct DockerInspectInfo {
    var created: String = ""
    var image: String = ""
    var restartPolicy: String = ""
    var network: String = ""
    var portBindings: [(container: String, host: String)] = []
    var mounts: [(source: String, destination: String)] = []
    var env: [String] = []

    // MARK: 容器转编排所需字段（仅新增，不改动上面既有字段，详情页解析不受影响）
    /// 容器名（docker inspect 顶层 Name，带前导 "/"）。
    var containerName: String = ""
    /// Config.Cmd：容器启动命令。
    var command: [String] = []
    /// Config.Entrypoint：入口点。
    var entrypoint: [String] = []
    /// Config.WorkingDir。
    var workingDir: String = ""
    /// Config.User。
    var user: String = ""
    /// Config.Hostname。
    var hostname: String = ""
    /// HostConfig.NetworkMode（host / none / bridge / 自定义网络名）。
    var networkMode: String = ""
    /// HostConfig.Privileged。
    var privileged: Bool = false
    /// HostConfig.CapAdd。
    var capAdd: [String] = []
    /// Config.Labels。
    var labels: [String: String] = [:]
    /// Config.Healthcheck.Test（健康检查命令，反向生成时仅作提示）。
    var healthcheck: [String] = []

    /// 宽松解析 docker inspect（数组，取第一个对象）。任何字段缺失都不影响其他字段。
    static func parse(_ text: String) -> DockerInspectInfo? {
        guard let data = text.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let object = array.first else { return nil }

        var info = DockerInspectInfo()
        info.created = object["Created"] as? String ?? ""
        // 顶层 Name 带前导 "/"，去掉后才是容器名。
        if let name = object["Name"] as? String {
            info.containerName = name.hasPrefix("/") ? String(name.dropFirst()) : name
        }
        if let config = object["Config"] as? [String: Any] {
            info.image = config["Image"] as? String ?? ""
            if let env = config["Env"] as? [String] { info.env = env }
            if let cmd = config["Cmd"] as? [String] { info.command = cmd }
            if let entrypoint = config["Entrypoint"] as? [String] { info.entrypoint = entrypoint }
            info.workingDir = config["WorkingDir"] as? String ?? ""
            info.user = config["User"] as? String ?? ""
            info.hostname = config["Hostname"] as? String ?? ""
            if let labels = config["Labels"] as? [String: String] { info.labels = labels }
            if let health = config["Healthcheck"] as? [String: Any],
               let test = health["Test"] as? [String] { info.healthcheck = test }
        }
        if let hostConfig = object["HostConfig"] as? [String: Any] {
            if let policy = hostConfig["RestartPolicy"] as? [String: Any] {
                info.restartPolicy = policy["Name"] as? String ?? ""
            }
            info.networkMode = hostConfig["NetworkMode"] as? String ?? ""
            info.privileged = hostConfig["Privileged"] as? Bool ?? false
            if let capAdd = hostConfig["CapAdd"] as? [String] { info.capAdd = capAdd }
        }
        if let networkSettings = object["NetworkSettings"] as? [String: Any] {
            if let networks = networkSettings["Networks"] as? [String: Any] {
                info.network = networks.keys.first ?? ""
            }
            if let ports = networkSettings["Ports"] as? [String: Any] {
                for (key, value) in ports {
                    let host = parseHostPorts(value)
                    info.portBindings.append((container: key, host: host))
                }
            }
        }
        if let mounts = object["Mounts"] as? [[String: Any]] {
            for mount in mounts {
                let source = mount["Source"] as? String ?? ""
                let destination = mount["Destination"] as? String ?? ""
                info.mounts.append((source: source, destination: destination))
            }
        }
        return info
    }

    /// Ports 的值是 [{HostIp, HostPort}] 数组或 nil。
    private static func parseHostPorts(_ value: Any) -> String {
        guard let list = value as? [[String: Any]] else { return "" }
        let parts = list.compactMap { item -> String? in
            let ip = item["HostIp"] as? String ?? ""
            let port = item["HostPort"] as? String ?? ""
            if port.isEmpty { return nil }
            return ip.isEmpty || ip == "0.0.0.0" ? port : "\(ip):\(port)"
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - 编排模板

/// 内置编排模板：对标 1Panel「编排模板」，选模板→改 yml→部署。
/// yml 采用 docker compose v2 语法；仅内置最小可用配置，用户可在 UI 里编辑。
struct ComposeTemplate: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    let symbol: String
    let yaml: String

    /// 内置模板集合。内容保持精简，够跑起来即可，详细配置交给用户编辑。
    static let builtins: [ComposeTemplate] = [
        ComposeTemplate(
            id: "nginx", name: "Nginx",
            detail: "Web server · port 80",
            symbol: "globe",
            yaml: """
            services:
              nginx:
                image: nginx:latest
                container_name: nginx
                ports:
                  - "80:80"
                restart: unless-stopped
            """
        ),
        ComposeTemplate(
            id: "redis", name: "Redis",
            detail: "In-memory cache · port 6379",
            symbol: "bolt.fill",
            yaml: """
            services:
              redis:
                image: redis:7-alpine
                container_name: redis
                ports:
                  - "6379:6379"
                restart: unless-stopped
            """
        ),
        ComposeTemplate(
            id: "mysql", name: "MySQL",
            detail: "Database · port 3306",
            symbol: "cylinder.split.1x2",
            yaml: """
            services:
              mysql:
                image: mysql:8.0
                container_name: mysql
                ports:
                  - "3306:3306"
                environment:
                  MYSQL_ROOT_PASSWORD: change_me
                restart: unless-stopped
            """
        ),
        ComposeTemplate(
            id: "postgres", name: "PostgreSQL",
            detail: "Database · port 5432",
            symbol: "cylinder.split.1x2",
            yaml: """
            services:
              postgres:
                image: postgres:16-alpine
                container_name: postgres
                ports:
                  - "5432:5432"
                environment:
                  POSTGRES_PASSWORD: change_me
                restart: unless-stopped
            """
        ),
        ComposeTemplate(
            id: "minio", name: "MinIO",
            detail: "Object storage · ports 9000/9001",
            symbol: "externaldrive.connected.to.line.below",
            yaml: """
            services:
              minio:
                image: minio/minio:latest
                container_name: minio
                ports:
                  - "9000:9000"
                  - "9001:9001"
                environment:
                  MINIO_ROOT_USER: minioadmin
                  MINIO_ROOT_PASSWORD: change_me
                command: server /data --console-address ":9001"
                restart: unless-stopped
            """
        ),
    ]
}

// MARK: - 容器进程

/// `docker top <id>` 的进程条目，对应详情页「进程」列表。
struct DockerProcess: Identifiable, Hashable {
    let pid: String
    let user: String
    let command: String

    var id: String { pid }

    /// 解析 `docker top -eo pid,user,args` 的输出：首行是表头，其余按 2+ 空格分列。
    static func parse(_ text: String) -> [DockerProcess] {
        let lines = text.split(separator: "\n").map { String($0) }
        guard lines.count > 1 else { return [] }
        return lines.dropFirst().compactMap { line in
            let cols = line.split(whereSeparator: { $0 == " " }).map(String.init)
            guard cols.count >= 3 else { return nil }
            return DockerProcess(pid: cols[0], user: cols[1], command: cols.dropFirst(2).joined(separator: " "))
        }
    }
}

// MARK: - 容器转编排（反向生成 compose yml）

/// 从现有容器反向生成的编排草稿：项目名 + yml + 需要用户注意的提示。
/// 这是「以原容器为基础创建的全新编排」，不是原地重编排——部署后生成新容器，原容器不动。
struct ComposeDraft: Identifiable, Hashable {
    let id = UUID()
    /// 建议项目名（后缀 -compose，避免与原容器名冲突）。
    let projectName: String
    /// 反向生成的 docker-compose.yml 内容，用户可在编辑页修改。
    let yaml: String
    /// 反向还原的注意事项（端口冲突、未完全还原的字段等）。
    let warnings: [String]
}

/// 反向生成 yml 的辅助工具（纯函数，不碰 SSH / 导航）。
enum ComposeGenerator {
    /// 把任意容器名转成合法的 compose 项目名 / service 名：小写、仅保留字母数字与 - _，非法字符转 -。
    static func sanitize(_ name: String) -> String {
        let mapped = name.lowercased().map { ch -> Character in
            (ch.isLetter || ch.isNumber || ch == "-" || ch == "_") ? ch : "-"
        }
        let collapsed = String(mapped).replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return trimmed.isEmpty ? "container" : trimmed
    }

    /// 生成建议项目名：<清洗后的容器名>-compose，保证与原容器不同名。
    static func projectName(from containerName: String) -> String {
        let base = sanitize(containerName)
        return "\(base)-compose"
    }

    /// 从 inspect 解析结果反向生成 yml。尽力还原，无法等价的部分写进 warnings。
    static func draft(from info: DockerInspectInfo) -> ComposeDraft {
        var lines: [String] = []
        var warnings: [String] = []

        // 顶部注释：明确这是全新编排，不是原地重编排，并说明环境变量为明文。
        lines.append("# Generated from container: \(info.containerName.isEmpty ? "—" : info.containerName)")
        lines.append("# New compose project — deployment creates a NEW container; the original container is untouched.")
        lines.append("# Review before deploying. Sensitive values below are written in plain text.")
        lines.append("")

        let serviceName = sanitize(info.containerName.isEmpty ? "service" : info.containerName)
        lines.append("services:")
        lines.append("  \(serviceName):")

        // 镜像：反向生成的唯一必需项。镜像缺失时给占位，提示用户补。
        let image = info.image.trimmingCharacters(in: .whitespaces)
        if image.isEmpty {
            lines.append("    image: REPLACE_ME:latest   # original image not detected — set it before deploying")
            warnings.append(L10n.t("Original image was not detected. Replace REPLACE_ME before deploying."))
        } else {
            lines.append("    image: \(ymlScalar(image))")
        }

        // 刻意不写 container_name：让 compose 以 <project>-<service>-1 命名新容器，从根上避免撞名。
        lines.append("    # container_name intentionally omitted — compose names the new container as <project>-<service>-1")

        // 重启策略
        if !info.restartPolicy.isEmpty, info.restartPolicy != "no" {
            lines.append("    restart: \(info.restartPolicy)")
        }

        // 端口映射
        if !info.portBindings.isEmpty {
            lines.append("    ports:")
            for binding in info.portBindings {
                // host 可能是 "80" 或 "127.0.0.1:80"，container 形如 "80/tcp"。
                let target = binding.container.replacingOccurrences(of: "/tcp", with: "")
                                                .replacingOccurrences(of: "/udp", with: "")
                let published = binding.host.isEmpty ? target : binding.host
                lines.append("      - \"\(published):\(target)\"")
            }
            warnings.append(L10n.t("Port conflicts: if the original container still occupies these ports, stop it or change the ports before deploying."))
        }

        // 挂载：source:destination
        if !info.mounts.isEmpty {
            lines.append("    volumes:")
            for mount in info.mounts where !mount.destination.isEmpty {
                let source = mount.source.isEmpty ? mount.destination : mount.source
                lines.append("      - \"\(source):\(mount.destination)\"")
            }
            warnings.append(L10n.t("Mounts are copied as bind paths. Verify the source paths exist on the target server."))
        }

        // 环境变量：明文写入（用户已确认），用 KEY: "value" 形式并转义引号/反斜杠。
        if !info.env.isEmpty {
            lines.append("    environment:")
            for pair in info.env {
                if let eq = pair.firstIndex(of: "=") {
                    let key = String(pair[..<eq])
                    let value = String(pair[pair.index(after: eq)...])
                    lines.append("      \(key): \(ymlDoubleQuoted(value))")
                } else {
                    // 无 "=" 的项（如仅声明传递的 KEY）保留为空字符串。
                    lines.append("      \(pair): \"\"")
                }
            }
            warnings.append(L10n.t("Environment variables are written in plain text, including secrets. Protect the compose file."))
        }

        // 启动命令 / 入口点
        if !info.entrypoint.isEmpty {
            lines.append("    entrypoint:")
            for item in info.entrypoint { lines.append("      - \(ymlScalar(item))") }
        }
        if !info.command.isEmpty {
            lines.append("    command:")
            for item in info.command { lines.append("      - \(ymlScalar(item))") }
        }

        // 工作目录 / 用户 / 主机名
        if !info.workingDir.isEmpty { lines.append("    working_dir: \(ymlScalar(info.workingDir))") }
        if !info.user.isEmpty { lines.append("    user: \(ymlScalar(info.user))") }
        if !info.hostname.isEmpty { lines.append("    hostname: \(ymlScalar(info.hostname))") }

        // 网络：host / none 用 network_mode；自定义网络仅提示，不自动生成（避免隐式建网）。
        let mode = info.networkMode.trimmingCharacters(in: .whitespaces)
        if mode == "host" || mode == "none" {
            lines.append("    network_mode: \(mode)")
        } else if !mode.isEmpty, mode != "bridge", !mode.hasPrefix("container:") {
            lines.append("    # Original network: \(mode) (custom network — add it manually if needed)")
            warnings.append(L10n.f("Original network \"%@\" is custom and was not recreated. Add it manually if needed.", mode))
        }

        // 特权 / capabilities
        if info.privileged { lines.append("    privileged: true") }
        if !info.capAdd.isEmpty {
            lines.append("    cap_add:")
            for cap in info.capAdd { lines.append("      - \(cap)") }
        }

        // 标签
        if !info.labels.isEmpty {
            lines.append("    labels:")
            for (key, value) in info.labels.sorted(by: { $0.key < $1.key }) {
                lines.append("      \(key): \(ymlDoubleQuoted(value))")
            }
        }

        // 健康检查：inspect 结构复杂，仅注释提示，不自动生成（避免误配）。
        if !info.healthcheck.isEmpty {
            lines.append("    # Original healthcheck: \(info.healthcheck.joined(separator: " "))")
            warnings.append(L10n.t("Healthcheck was not recreated automatically; review it manually."))
        }

        // 通用免责提示
        warnings.append(L10n.t("This is a best-effort draft from container inspection. Not all settings can be reproduced; review before deploying."))

        return ComposeDraft(
            projectName: projectName(from: info.containerName),
            yaml: lines.joined(separator: "\n") + "\n",
            warnings: warnings
        )
    }

    /// 简单标量：无特殊字符直接输出，否则加双引号。
    private static func ymlScalar(_ value: String) -> String {
        let needsQuote = value.isEmpty || value.contains(" ") || value.contains(":") ||
                         value.contains("#") || value.contains("\"") || value.contains("'") ||
                         value.hasPrefix("-") || value.hasPrefix("[") || value.hasPrefix("{")
        return needsQuote ? ymlDoubleQuoted(value) : value
    }

    /// 双引号包裹并转义反斜杠与双引号。
    private static func ymlDoubleQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
                           .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
