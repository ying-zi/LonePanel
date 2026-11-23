# LonePanel

纯客户端 iOS 运维 App，通过 SSH / SFTP 直连服务器执行命令与管理文件。服务器端零安装，所有面板能力由 App 本地拼装命令远程执行。

- 语言：Swift
- UI：SwiftUI + iOS 26 Liquid Glass 设计语言
- 最低部署：iOS 26.0
- 包管理：Swift Package Manager（SSH 底层依赖 SwiftNIO SSH）
- Bundle ID：`com.lone.lonepanel`

## 当前状态

项目骨架：五个 Tab（网站 / Docker / 数据库 / 文件 / 设置）空壳页，无业务功能代码。

## 目录结构

根目录平铺 `Core` 与五个平级模块，无 `Modules` 中间层。每一层都遵循同一规则：一个 Core 全局目录 + 若干平级功能模块；Core 只放本层两个以上模块共用的东西，模块私有物留在模块内。

```
LonePanel/
├── App/                          顶层组装层
│   ├── LonePanelApp.swift        @main 入口
│   ├── TabRegistry.swift         Tab 注册表（唯一登记具体模块处）
│   └── ContentView.swift         遍历注册表装配 Tab
├── Core/                         根级全局（五个 Tab 共用）
│   ├── Navigation/TabModule.swift
│   ├── Theme/                    主题、共用空壳视图
│   ├── SSH/  SFTP/  Keychain/  Logging/   预留
├── Website/                      模块出口 + 空壳 + 内部 Core 与子模块占位
│   ├── WebsiteTab.swift / WebsiteView.swift
│   └── Core/ PHP/ NodeJS/ ReverseProxy/ Certificate/ NginxEditor/
├── Docker/    DockerTab/View + Core/ Containers/ Images/ Compose/
├── Database/  DatabaseTab/View + Core/ MySQL/ PostgreSQL/ Redis/
├── Files/     FilesTab/View + Core/ Browser/ Editor/
├── Settings/  SettingsTab/View + Core/
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
