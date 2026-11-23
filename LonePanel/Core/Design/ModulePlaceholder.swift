import SwiftUI

/// 各模块空壳页共用的占位视图。
/// 采用 iOS 26 Liquid Glass：NavigationStack 的导航栏/工具栏由系统自动应用玻璃材质，
/// 主要操作按钮显式使用 .glass 样式。
struct ModulePlaceholder: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: AppTheme.placeholderIconSize))
                    .foregroundStyle(.tint)

                Text(title)
                    .font(.title2.weight(.semibold))

                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("即将推出") { }
                    .buttonStyle(.glass)
                    .disabled(true)
            }
            .padding()
            .frame(maxWidth: AppTheme.placeholderMaxWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(title)
        }
    }
}
