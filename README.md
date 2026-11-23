# LonePanel

纯客户端 iOS 运维 App，通过 SSH / SFTP 直连服务器执行命令与管理文件。服务器端零安装，所有面板能力由 App 本地拼装命令远程执行。

- 语言：Swift
- UI：SwiftUI + iOS 26 Liquid Glass 设计语言
- 最低部署：iOS 26.0
- 包管理：Swift Package Manager（SwiftNIO SSH + swift-crypto）
- Bundle ID：`com.lone.lonepanel`

## 当前状态

五个 Tab（网站 / Docker / 数据库 / 文件 / 设置）可切换；网站/Docker/数据库仍为空壳。
设置模块已实现第一刀「我的服务器」：服务器列表、默认/当前标注、左滑编辑/设为默认/删除、添加/编辑表单、真实 SSH 测试连接、凭证存钥匙串、临时切换仅当前进程有效。
文件模块的视觉与交互对齐 iOS 26/27 系统「文件」App：
- 进入规则：冷启动未设默认目录进 `/`，已设进默认目录；单击当前「文件」Tab 清空导航栈回默认目录入口。
- **整行可点**：列表/网格中每个条目（文件夹与文件）由系统原生 `NavigationLink`/`Button` 承载，整行都是点击热区，不是只有文件名可点。
- 导航：NavigationStack 逐层 push；顶部为「返回/前进」胶囊（自维护历史游标，系统无原生前进控件），标题带下拉箭头展开位置层级浮层（根目录 + 逐级、当前高亮、点击跳转、点遮罩收起）；标题内联 + ⋯ 菜单（选择/新建文件夹/排序/视图切换/显示隐藏/默认目录/重连）。
- 列表 / 图标网格两种视图，行高/间距/圆角/分组全走系统 List 默认，系统图标按类型着色（文件夹蓝、图像紫、代码青、归档橙）；下拉刷新、常驻系统搜索。
- 单击目录进入下一级，单击文件走系统 QuickLook 全屏预览；长按上下文菜单（顶部拷贝/移动/共享快捷三连 + 快速查看/获取信息/重命名/压缩/删除），左滑重命名/删除/移动。
- 多选态：顶部「全选/取消全选 + N 项 + 完成」，底部 Liquid Glass 浮动胶囊工具条（分享/移动/复制/压缩/删除 + ⋯）；按名称/种类/日期/大小排序与升降序；显示隐藏文件开关；删除系统危险路径（/etc、/usr 等）二次确认。
- 「获取信息」面板（系统 Info 风格）展示种类/大小/修改日期/权限/属主/位置；分享走系统分享面板。
- 移动/复制目标目录选择、批量压缩借已认证 SSH 连接执行远端 `mv/cp/zip`；SFTP v3 协议自实现，零新增依赖。
- 菜单内容（上下文菜单/⋯菜单/批量菜单）按项目需求自定义，整体视觉与交互逻辑对齐系统文件 App。

## 目录结构

根目录平铺 `Core` 与五个平级模块，无 `Modules` 中间层。每一层都遵循同一规则：一个 Core 全局目录 + 若干平级功能模块；Core 只放本层两个以上模块共用的东西，模块私有物留在模块内。

```
LonePanel/
├── App/                          顶层组装层
│   ├── LonePanelApp.swift        @main 入口
│   ├── TabRegistry.swift         Tab 注册表（唯一登记具体模块处）
│   └── ContentView.swift         遍历注册表装配 Tab
├── Core/                         根级全局（五个 Tab 共用）
│   ├── Navigation/TabModule.swift / TabNavigationCenter.swift（Tab 重选回根）
│   ├── Theme/                    主题、共用空壳视图
│   ├── Session/                  ServerConnectionInfo / ServerSession（连接快照与单例）
│   ├── SSH/                      SSHSession（真实握手与 exec）、私钥解析、subsystem 子通道
│   ├── Keychain/                 凭证存取
│   ├── Logging/                  预留
├── Website/                      模块出口 + 空壳 + 内部 Core 与子模块占位
│   ├── WebsiteTab.swift / WebsiteView.swift
│   └── Core/ PHP/ NodeJS/ ReverseProxy/ Certificate/ NginxEditor/
├── Docker/    DockerTab/View + Core/ Containers/ Images/ Compose/
├── Database/  DatabaseTab/View + Core/ MySQL/ PostgreSQL/ Redis/
├── Files/     FilesTab/View
│   ├── Core/        SFTP v3 客户端与协议、默认目录持久化、文件类型/排序
│   ├── Browser/     原生文件浏览器（Model + View + 逐层导航/工具栏/目标选择器）
│   └── Detail/      获取信息面板 + 系统分享封装
├── Settings/  SettingsTab/View
│   ├── Core/       Server 模型、列表落盘、具体会话实现
│   └── Servers/    我的服务器列表页、添加/编辑表单
└── Resources/Assets.xcassets/
```

**依赖方向**：功能模块 → 本层 Core → 根 Core；平级模块互不依赖；下层不反向依赖上层；根 Core 不依赖任何模块。App 层是唯一组装者。

**可插拔**：删除任意模块目录 + 删除 `TabRegistry.modules` 中对应一行，项目仍可编译。

## 本地运行

需要 Xcode 26（含 iOS 26 SDK）。

```bash
open LonePanel.xcodeproj
# 选择 iOS 26 模拟器，Cmd+R 运行
```

首次打开 Xcode 会自动解析 SPM 依赖（SwiftNIO SSH）。

## CI / 构建

推送 tag 触发 `.github/workflows/build.yml`，在 `macos-26`（Xcode 26）上构建未签名 IPA 并发布到 Release：

| tag 前缀 | 示例 | 构建类型 | Release 标记 |
|---|---|---|---|
| `t` | `t1.0.0` | 测试构建 | pre-release |
| `v` | `v1.0.0` | 正式构建 | 正式版本 |

产物命名：`LonePanel-<版本>-<构建时间UTC>-<channel>-unsigned.ipa`。未签名 IPA 可通过 AltStore / SideStore 侧载安装。
