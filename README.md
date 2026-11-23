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
文件模块已实现原生 SFTP 文件浏览器，参照系统「文件」App 交互：
- 进入规则：冷启动未设默认目录进 `/`，已设进默认目录；单击当前「文件」Tab 回默认目录入口。
- 顶部路径摘要（末两级），点击展开逐级浮层，首行「根目录」可一键回根，点遮罩收起。
- 列表整行可点进详情；左滑重命名/删除/移动；多选态支持批量移动/复制/删除/压缩；显示隐藏文件开关；删除系统危险路径（/etc、/usr 等）二次确认。
- 文件详情页：文本只读预览/关键字搜索/编码切换（UTF-8/UTF-16/GB18030/Latin-1）、图片捏合缩放、底部操作条（编辑/下载/重命名/移动/删除）、编辑未保存退出确认、系统分享面板导出、底部属性（大小/修改时间/权限/属主）。
- 批量移动/复制/压缩借已认证 SSH 连接执行远端 `mv/cp/zip`；SFTP v3 协议自实现，零新增依赖。

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
│   ├── Core/        SFTP v3 客户端与协议、默认目录持久化、文件类型/编码
│   ├── Browser/     原生文件浏览器（Model + View + 路径浮层/目标选择器）
│   └── Detail/      文件详情页（预览/编辑/属性/系统分享）
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
