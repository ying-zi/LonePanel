import SwiftUI

/// 容器列表行（列表视图）：紧凑单行，左色条 + 名称/状态 + 镜像/端口 + ⋯。
/// 列表里不放底部按钮，主操作收进 ⋯ 菜单，避免行内按钮过密误触。
struct ContainerListRow: View {
    let container: DockerContainer
    let model: ContainerListModel
    let onOpen: () -> Void
    let onMore: () -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            Color(.secondarySystemBackground)
            HStack(spacing: 0) {
                StatusStripe(state: container.state)
                    .clipShape(RoundedRectangle(cornerRadius: 2))

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(container.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            StatusBadge(state: container.state)
                                .fixedSize()
                        }
                        Text(container.image)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let port = container.primaryPort {
                            Text(port)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Button(action: onMore) {
                        Image(systemName: "ellipsis")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 12)
                .padding(.trailing, 12)
                .padding(.vertical, 11)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }
}
