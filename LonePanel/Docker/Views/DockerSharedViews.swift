import SwiftUI

/// 状态语义色：全模块统一，保证色条、徽章、圆环一致。
enum DockerStateStyle {
    static func color(_ state: DockerContainerState) -> Color {
        switch state {
        case .running: return .green
        case .paused: return .orange
        case .stopped: return .gray
        }
    }

    static func label(_ state: DockerContainerState) -> String {
        switch state {
        case .running: return L10n.t("Running")
        case .paused: return L10n.t("Paused")
        case .stopped: return L10n.t("Stopped")
        }
    }
}

/// 容器卡片左侧状态色条。
struct StatusStripe: View {
    let state: DockerContainerState

    var body: some View {
        Rectangle()
            .fill(DockerStateStyle.color(state))
            .frame(width: 4)
    }
}

/// 状态徽章。
struct StatusBadge: View {
    let state: DockerContainerState

    var body: some View {
        Text(DockerStateStyle.label(state))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(DockerStateStyle.color(state))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(DockerStateStyle.color(state).opacity(0.14), in: Capsule())
    }
}

/// 占用率圆环：进度按 0...100 映射，超过阈值自动变橙/红。
/// 标签放在环下方的正常布局流中（不再用 overlay+offset 浮在环外），避免压住下一行端口文字；
/// 环尺寸与线宽用 @ScaledMetric 跟随系统字体缩放，配合 minimumScaleFactor 适配 Dynamic Type。
struct UsageRing: View {
    let value: Double
    let label: String
    var tint: Color? = nil

    @ScaledMetric(relativeTo: .caption2) private var ringSize: CGFloat = 48
    @ScaledMetric(relativeTo: .caption2) private var ringLineWidth: CGFloat = 6

    private var normalized: Double {
        min(max(value / 100, 0), 1)
    }

    private var ringColor: Color {
        if let tint { return tint }
        if value >= 85 { return .red }
        if value >= 70 { return .orange }
        return .blue
    }

    /// 极小非零值显示 <1% 而非 0%，避免误读为无数据。
    private var percentText: String {
        if value > 0 && value < 1 { return "<1%" }
        return "\(Int(value.rounded()))%"
    }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(Color(.systemGray5), lineWidth: ringLineWidth)
                Circle()
                    .trim(from: 0, to: normalized)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: ringLineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: normalized)
                Text(percentText)
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(ringColor)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            .frame(width: ringSize, height: ringSize)

            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// 运行中容器的资源区：双环 + 内存绝对值 + 运行时长。
/// 普通字体横向排布；辅助功能超大字体（AX）改为纵向，避免一行挤爆。
struct ResourceRingsView: View {
    let container: DockerContainer
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    ringsRow
                    infoColumn
                }
            } else {
                HStack(alignment: .center, spacing: 16) {
                    ringsRow
                    infoColumn
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var ringsRow: some View {
        HStack(spacing: 16) {
            UsageRing(value: container.usage.cpuPercent, label: "CPU")
            UsageRing(value: container.usage.memPercent, label: L10n.t("Memory"), tint: .purple)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var infoColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(container.usage.memoryText, systemImage: "memorychip")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Label(runtimeText, systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    /// 从 Status "Up 3 days" 里取出运行时长，做轻量中文化。
    /// 兼容 "Up 2 days (healthy)" 之类带后缀的输出，并覆盖秒级与月级单位。
    private var runtimeText: String {
        let s = container.statusText
        guard s.lowercased().hasPrefix("up") else { return s }
        var text = String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        // 去掉 "(healthy)" / "(Paused)" 等括号后缀
        if let paren = text.firstIndex(of: "(") {
            text = String(text[..<paren]).trimmingCharacters(in: .whitespaces)
        }
        // 用正则把「数字 + 单位（含单复数）」整体替换，避免逐个字符串替换时
        // 先替换单数把它们变成 "秒s" 这类残留（曾导致运行时长后面多一个字母 s）。
        // 单位从长到短排列，正则一次匹配整个单词边界，单复数都覆盖。
        let unitMap: [String: String] = [
            "months": L10n.t("months"), "month": L10n.t("months"),
            "weeks": L10n.t("weeks"), "week": L10n.t("weeks"),
            "days": L10n.t("days"), "day": L10n.t("days"),
            "hours": L10n.t("hours"), "hour": L10n.t("hours"),
            "minutes": L10n.t("minutes"), "minute": L10n.t("minutes"),
            "seconds": L10n.t("seconds"), "second": L10n.t("seconds")
        ]
        // 复数在前的英文单词顺序替换；译文只在 value 里，绝不拿译文当搜索 key
        // （原代码用 L10n.t("months") 当搜索串，中文模式下变成拿"个月"找"months"，
        //  单数再替换就把 "months" 拆成 "个月s"，这就是运行时长后多一个 s 的根因）。
        for unit in ["months", "month", "weeks", "week", "days", "day", "hours", "hour", "minutes", "minute", "seconds", "second"] {
            if let translated = unitMap[unit], translated != unit {
                text = text.replacingOccurrences(of: unit, with: translated)
            }
        }
        return text.isEmpty ? L10n.t("Running") : L10n.f("Run %@", String(describing: (text)))
    }
}

/// 停止/暂停容器的中间区：显示镜像名。
struct ImageLineView: View {
    let image: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox")
                .foregroundStyle(.secondary)
            Text(image)
                .font(.subheadline.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 16)
    }
}

/// 卡片操作栏：主操作（按状态）+ 日志（任何状态可用）+ 更多（重启/暂停/删除等）。
struct ContainerActionsBar: View {
    let container: DockerContainer
    let model: ContainerListModel
    let onLogs: () -> Void
    let onMore: () -> Void
    @State private var acting = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Task {
                    acting = true
                    defer { acting = false }
                    _ = await model.primaryAction(for: container)
                    await model.refresh()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: primaryIcon)
                    Text(model.primaryActionLabel(for: container))
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(acting)

            Button(action: onLogs) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text.magnifyingglass")
                    Text(L10n.t("Logs"))
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(action: onMore) {
                Image(systemName: "ellipsis")
                    .frame(width: 28)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var primaryIcon: String {
        switch container.state {
        case .running: return "pause.fill"
        case .paused: return "play.fill"
        case .stopped: return "play.fill"
        }
    }
}
