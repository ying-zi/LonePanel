# LonePanel

纯客户端 iOS 运维 App，通过 SSH / SFTP 直连服务器执行命令与管理文件。服务器端零安装，所有面板能力由 App 本地拼装命令远程执行。

- 语言：Swift
- UI：SwiftUI + iOS 26 Liquid Glass 设计语言
- 最低部署：iOS 26.0
- 包管理：Swift Package Manager（SSH 底层依赖 SwiftNIO SSH）
- Bundle ID：`com.lone.lonepanel`

## 当前状态

项目骨架：5 个 Tab（网站 / Docker / 数据库 / 文件 / 设置）空壳页，无业务功能代码。

## 目录结构

```
LonePanel/
├── LonePanelApp.swift          App 入口
├── App/                        组装层（TabView 等）
├── Core/                       全局层：所有模块共用
│   ├── Design/                 设计令牌、共用占位视图
│   └── Navigation/             Tab 定义
└── Modules/                    功能模块，彼此不引用
    ├── Website/
    ├── Docker/
    ├── Database/
    ├── Files/
    └── Settings/
```

约定：全局共用代码放 `Core`；仅某模块使用的代码放该模块目录内；模块之间不互相引用。

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

产物命名：`LonePanel-<版本>-<构建时间UTC>-<channel>-unsigned.ipa`，例如 `LonePanel-1.0.0-20261123-061500-testing-unsigned.ipa`。

未签名 IPA 可通过 AltStore / SideStore 侧载安装。
