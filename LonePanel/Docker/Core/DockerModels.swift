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

    /// 宽松解析 docker inspect（数组，取第一个对象）。任何字段缺失都不影响其他字段。
    static func parse(_ text: String) -> DockerInspectInfo? {
        guard let data = text.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let object = array.first else { return nil }

        var info = DockerInspectInfo()
        info.created = object["Created"] as? String ?? ""
        if let config = object["Config"] as? [String: Any] {
            info.image = config["Image"] as? String ?? ""
            if let env = config["Env"] as? [String] { info.env = env }
        }
        if let hostConfig = object["HostConfig"] as? [String: Any],
           let policy = hostConfig["RestartPolicy"] as? [String: Any] {
            info.restartPolicy = policy["Name"] as? String ?? ""
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
