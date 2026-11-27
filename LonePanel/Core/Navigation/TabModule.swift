import SwiftUI

/// Tab 模块的数据结构。根 Core 只定义类型，不认识任何具体模块。
/// 各功能模块导出一个 TabModule 实例，由 App 层的注册表统一登记。
struct TabModule: Identifiable {
    let id: String
    let title: String
    let symbolName: String
    /// 类型擦除，使 App 层无需知道具体视图类型。
    let view: AnyView
    /// 模块启动钩子：只由模块自己提供，App 层统一调用。
    /// 删除模块时连同注册表那一行一起删，项目仍可编译。
    let configure: () -> Void
    /// 该模块是否显示悬浮终端按钮。文件/设置不需要，容器/网站/数据库需要。
    let showsFloatingTerminal: Bool
    /// 是否核心模块（底座）：设置页不可被用户关闭。
    let isCore: Bool
    /// 模块注册到设置页的设置项（可为空）。用类型擦除，设置页只需遍历展示。
    let settingsSection: AnyView?

    init(
        id: String,
        title: String,
        symbolName: String,
        view: AnyView,
        configure: @escaping () -> Void = {},
        showsFloatingTerminal: Bool = false,
        isCore: Bool = false,
        settingsSection: AnyView? = nil
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.view = view
        self.configure = configure
        self.showsFloatingTerminal = showsFloatingTerminal
        self.isCore = isCore
        self.settingsSection = settingsSection
    }

    /// 便捷构造：接受任意 View，内部做类型擦除。
    /// 需要注册设置项的模块请用完整 init（直接传 settingsSection: AnyView?）。
    init<Content: View>(
        id: String,
        title: String,
        symbolName: String,
        configure: @escaping () -> Void = {},
        showsFloatingTerminal: Bool = false,
        isCore: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            id: id,
            title: title,
            symbolName: symbolName,
            view: AnyView(content()),
            configure: configure,
            showsFloatingTerminal: showsFloatingTerminal,
            isCore: isCore,
            settingsSection: nil
        )
    }
}

// MARK: - 设置入口环境注入

/// 打开设置页的动作。由根视图按「入口态 / 调用态」注入：
/// - 入口态（单模块 / 纯终端形态）：注入动作，模块在自己的导航栏右上角显示设置齿轮；
/// - 多模块形态：设置已是底部 Tab，不注入，右上角不重复出现；
/// - 调用态（被其它模块以能力 API 唤起）：调用方不注入，齿轮自动隐藏，界面只干活。
private struct OpenSettingsEnvironmentKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var openSettings: (() -> Void)? {
        get { self[OpenSettingsEnvironmentKey.self] }
        set { self[OpenSettingsEnvironmentKey.self] = newValue }
    }
}

/// 模块导航栏里的设置齿轮。仅当根视图注入了 openSettings（入口态）时出现。
/// 各模块把它放进自己的 `.toolbar` trailing，与自身按钮由系统统一排布，
/// 不再需要外层附加的独立顶栏——从根上消除双顶栏和右上角位置冲突。
struct SettingsGearButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let openSettings {
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .semibold))
            }
            .help(L10n.t("Settings"))
            .accessibilityLabel(L10n.t("Settings"))
        }
    }
}

/// 统一的「收起 / 关闭」按钮：右上角向下小箭头（chevron.down）。
/// 语义是「把面板收起来」——诊断、日志、终端、文件调用态等纯关闭场景用这个。
/// 注意与 `DoneCheckmarkButton` 区分：那是「操作已完成/确认」用勾，别混用。
struct DismissChevronButton: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 16, weight: .semibold))
        }
        .help(L10n.t("Close"))
        .accessibilityLabel(L10n.t("Close"))
    }
}

/// 统一的「操作已完成 / 确认」按钮：右上角勾（checkmark）。
/// 语义是「这件事做完了」——调用态详情看完、多选完成、输入完成等，与文件多选态右上角的勾同源同款。
/// 样式刻意与文件多选完成勾一致（size 17 bold / .primary / 32×32），保证全 App 通用图形统一。
/// 用图形代替文字 Done：能图形化表达就别用文案。与 `DismissChevronButton`（收起/关闭）分工明确，勿混用。
struct DoneCheckmarkButton: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button { dismiss() } label: {
            Image(systemName: "checkmark")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .help(L10n.t("Done"))
        .accessibilityLabel(L10n.t("Done"))
    }
}

/// 统一的「取消」按钮：左上角叉（xmark）。
/// 语义是「放弃这次表单操作」——sheet/表单左上角的取消，与完成勾、收起箭头组成三件套。
/// 与 `DoneCheckmarkButton`（完成）、`DismissChevronButton`（收起）分工明确，勿混用。
/// 注意：仅用于工具栏取消；alert 确认弹窗里的标准「取消」按钮保留文字（iOS HIG）。
struct CancelXButton: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .help(L10n.t("Cancel"))
        .accessibilityLabel(L10n.t("Cancel"))
    }
}
