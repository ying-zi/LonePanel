import SwiftUI

/// 容器卡片（卡片视图）：左侧状态色条 + 上部名称/状态 + 中部智能切换资源/镜像 + 下部操作栏。
struct ContainerCard: View {
    let container: DockerContainer
    let model: ContainerListModel
    let onOpen: () -> Void
    let onMore: () -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            // 用 grouped cell 专用白色背景（secondarySystemGroupedBackground），
            // 与页面 systemGroupedBackground 拉开层次，让卡片轮廓清晰可见。
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemGroupedBackground))

            HStack(spacing: 0) {
                // 色条做成卡片内部的小圆角条，上下留白，避免像挂在卡片外侧。
                StatusStripe(state: container.state)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .padding(.vertical, 14)

                VStack(alignment: .leading, spacing: 0) {
                    // 上部：名称 + 状态
                    HStack {
                        Text(container.name)
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Spacer(minLength: 4)
                        StatusBadge(state: container.state)
                            .fixedSize()
                    }

                    // 中部：运行中显示双环资源，暂停/停止显示镜像名
                    if container.state == .running && container.usage.hasData {
                        ResourceRingsView(container: container)
                    } else {
                        ImageLineView(image: container.image)
                    }

                    // 端口（次要信息，卡片下一行紧凑展示）
                    if let port = container.primaryPort {
                        HStack(spacing: 4) {
                            Image(systemName: "network")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(port)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            if container.extraPortCount > 0 {
                                Text("+\(container.extraPortCount)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.bottom, 8)
                    }

                    Divider()

                    // 下部：快捷操作
                    ContainerActionsBar(container: container, model: model, onMore: onMore)
                        .padding(.top, 10)
                }
                .padding(.leading, 12)
                .padding(.trailing, 14)
                .padding(.vertical, 14)
            }
        }
        // 先裁成圆角再投影，保证色条/内容都严格落在卡片圆角内，阴影不会漏出直角。
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }
}
