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
        case .running: return "运行中"
        case .paused: return "暂停中"
        case .stopped: return "已停止"
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
struct UsageRing: View {
    let value: Double
    let label: String
    var tint: Color? = nil

    private var normalized: Double {
        min(max(value / 100, 0), 1)
    }

    private var ringColor: Color {
        if let tint { return tint }
        if value >= 85 { return .red }
        if value >= 70 { return .orange }
        return .blue
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(.systemGray5), lineWidth: 6)
            Circle()
                .trim(from: 0, to: normalized)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.3), value: normalized)
            Text("\(Int(value.rounded()))%")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(ringColor)
                .minimumScaleFactor(0.7)
        }
        .frame(width: 52, height: 52)
        .overlay(alignment: .bottom) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .offset(y: 14)
        }
    }
}

/// 运行中容器的资源区：双环 + 内存绝对值 + 运行时长。
struct ResourceRingsView: View {
    let container: DockerContainer

    var body: some View {
        HStack(spacing: 16) {
            UsageRing(value: container.usage.cpuPercent, label: "CPU")
            UsageRing(value: container.usage.memPercent, label: "内存", tint: .purple)
            VStack(alignment: .leading, spacing: 6) {
                Label(container.usage.memoryText, systemImage: "memorychip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Label(runtimeText, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    /// 从 Status "Up 3 days" 里取出运行时长，做轻量中文化。
    private var runtimeText: String {
        let s = container.statusText
        guard s.lowercased().hasPrefix("up") else { return s }
        var text = String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        text = text.replacingOccurrences(of: "days", with: "天")
        text = text.replacingOccurrences(of: "day", with: "天")
        text = text.replacingOccurrences(of: "hours", with: "小时")
        text = text.replacingOccurrences(of: "hour", with: "小时")
        text = text.replacingOccurrences(of: "minutes", with: "分钟")
        text = text.replacingOccurrences(of: "minute", with: "分钟")
        text = text.replacingOccurrences(of: "weeks", with: "周")
        text = text.replacingOccurrences(of: "week", with: "周")
        text = text.replacingOccurrences(of: "months", with: "月")
        text = text.replacingOccurrences(of: "month", with: "月")
        return "运行 \(text)"
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
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 16)
    }
}

/// 卡片操作栏：主操作 + 重启 + 更多。
struct ContainerActionsBar: View {
    let container: DockerContainer
    let model: ContainerListModel
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
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(acting)

            Button {
                Task {
                    acting = true
                    defer { acting = false }
                    _ = await model.restart(container)
                    await model.refresh()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                    Text("重启")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(acting || container.state == .stopped)

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
