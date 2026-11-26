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
                return "Port must be a number between 1 and 65535 (\(p.hostPort):\(p.containerPort))"
            }
        }
        for m in mounts where !m.hostPath.isEmpty || !m.containerPath.isEmpty {
            guard m.hostPath.hasPrefix("/") else { return "Host path must be absolute (start with /): \(m.hostPath)" }
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
}
