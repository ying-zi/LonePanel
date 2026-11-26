# LonePanel — AI 接手手册

> 这份文档面向「第一次接触本项目的 AI / 开发者」。读完它，你应当能理解 App 的运行机制、设计思路、目标，以及怎么安全地接手继续开发、怎么发版。**动手前请先读第 2、3、4 节（目标、铁律、架构）——这里记录了多条用户反复强调、不可违背的约束。**

---

## 1. 一句话定位与终极目标

**LonePanel 是一个纯客户端 iOS 运维 App，通过 SSH / SFTP 直连服务器执行命令、管理文件与容器/数据库；服务器端零安装，所有"面板"能力由 App 本地拼装命令远程执行。**

- **终极目标（用户原话）：干掉 Web 管理面板 / WorkBuddy 管理面板，把所有服务器运维能力收进这个 App。**
- 由此衍生的产品原则：功能要**闭环**、要**自助**——不能是"点了半截还得去别处补一步"的半成品。用户反复强调："要始终自助一点，具体功能实现要完整思考逻辑是否闭环、功能是否完善。"
- 当前阶段：**底座能力已基本完善**（SSH 底座 + 可插拔模块 + 终端 + 文件 + Docker + 数据库首版），**网站模块仍是空壳**，各模块功能在真机反馈中持续打磨。

### 硬性技术约束

| 项 | 值 |
|---|---|
| 语言 / UI | Swift / SwiftUI，iOS 26 Liquid Glass 设计语言 |
| 最低系统 | iOS 26.0 |
| Bundle ID | `com.lone.lonepanel` |
| 依赖（SPM） | `swift-nio-ssh`、`swift-crypto`、`SwiftTerm` |
| 仓库 | `ying-zi/LonePanel`，工作分支 `feature/module-architecture` |
| 凭据存储 | iOS 钥匙串 `KeychainStore`（密码永不落明文、不进命令行） |
| 当前基线 | tag `t1.70.0`，版本 1.70.0（详见第 9 节） |

---

## 2. 不可违背的铁律（用户多次强调，违反必被回退）

1. **终端是底座，不是模块。** `ModuleID` 里**绝不能**出现 `terminalUI`/`terminal`。SSH 终端恒可用；所有内容模块关闭时，App 直接进入全屏终端（合法终态）。设置页里**没有**"终端界面"开关。
2. **关模块 = 关入口，不关能力。** 开关只决定某个模块是否出现在底部 Tab；底层能力（SSH、终端、文件浏览、通知、日志）不受开关影响、恒可用。
3. **入口态 / 调用态分离。**
   - 入口态：模块作为 Tab 出现，拥有完整 UI 与设置齿轮。
   - 调用态：被其它模块以能力 API 唤起（如容器卷点击 → 打开文件浏览），**只干活**——独立会话、注入上下文参数、**不读写用户偏好、不污染单例导航栈、看完下拉即走**。
   - 模块间互调**唯一通道**是 `ModuleCoordinator`，禁止直接引用别的模块的视图/模型。
4. **跨模块连接物理隔离。** 终端（保活会重连）、Docker、数据库各有**独立的 SSH 连接实例**。终端重连会 `session.close()` 打断在途命令，若共用连接会让容器列表/数据库查询被掐断——这是血的教训，不要再合并。
5. **所有远程命令：外部输入必须 shell 引号转义；密码必须走环境变量，绝不拼进命令行。**
6. **文件页保持系统原生 insetGrouped 大卡片**，不要改成"每行一个小卡片"（用户明确反对过，已回退）。
7. **终端右上角只保留一个圆形箭头重连按钮**；不要垃圾桶、不要断开/连接按钮；**清屏移到 Ctrl+L（byte 0x0C）**。
8. **设置齿轮融入模块自己的 toolbar**，由环境注入控制显隐；不要外层附加独立顶栏（曾造成双顶栏）。
9. **支持 Dynamic Type**；卡片背景要明显、左色条内缩在卡片内。
10. **UI 形态切换时卡片行为**：从 0 模块开启第一个模块（terminalFocus→moduleFocus）设置卡片必须正常；从 <2 开到 ≥2 模块（进入多 Tab）要主动收起全屏设置卡片，露出底部 Tab；关到 0 模块也要收起卡片（否则终端键盘顶乱卡片）。

---

## 3. 目标与能力边界

- App 是**通用服务器运维工具**，不假设用户是 root：连接后自动探测权限（root / 免密 sudo / 普通用户），业务命令按权限自动加 `sudo -n`，按服务器缓存。
- 命令在**服务器本地**执行：数据库用服务器上的 `mysql`/`mariadb`/`psql`/`mongosh`/`redis-cli` 客户端，Docker 用 `docker`，文件用 SFTP + SSH 回退。**App 不解析私有协议、不需要服务器装 Agent。**
- 侧载分发：`t*` tag 产出未签名 IPA，用 AltStore / SideStore 安装。

---

## 4. 架构：底座 + 可插拔模块

### 4.1 三种根形态（`ModuleVisibility.RootMode`）

`App/ContentView.swift` 是唯一根视图，按**启用的内容模块数量**（不含恒开的设置）决定形态：

| 内容模块数 | RootMode | 表现 |
|---|---|---|
| 0 | `.terminalFocus` | 全屏终端（底座兜底） |
| 1 | `.moduleFocus(TabModule)` | 单模块全屏 |
| ≥2 | `.tabs` | 正常 TabView |

`ModuleVisibility`（单例，`App/TabRegistry.swift`）管理开关，持久化前缀 `com.lone.lonepanel.module.enabled.`。`ModuleID = {website, docker, database, files, settings}`，其中 `settings.isCore = true` 恒开不可关；`enabled` 允许为空集（全关是合法终态）。

### 4.2 可插拔机制

- 每个模块导出一个 `TabModule`（`Core/Navigation/TabModule.swift`）：类型擦除的 `view`、`configure` 启动钩子、`showsFloatingTerminal`、`isCore`、`settingsSection`。
- `TabRegistry.modules` 是**全 App 唯一登记具体模块的地方**。删除一个模块 = 删其目录 + 删注册表对应一行，项目仍可编译。
- 依赖方向：`功能模块 → 本层 Core → 根 Core`；平级模块互不依赖；下层不反向依赖上层；App 层是唯一组装者。
- `SettingsTab.module.configure` 负责把 `SettingsServerSession` 注入根 Core 的会话单例——**模块自己注入实现，App 层不认识具体类型**。

### 4.3 设置入口的环境注入

`Core/Navigation/TabModule.swift` 定义 `openSettings` EnvironmentKey、`SettingsGearButton`：

- 入口态（单模块/纯终端）：根视图经 `focusView` 注入 `openSettingsAction`，模块齿轮出现在自己 toolbar 的 trailing。
- 多模块：设置已是底部 Tab，不注入 → 无重复齿轮。
- 调用态：调用方不注入 → 齿轮自动隐藏。

**设置 sheet 必须挂在 `ContentView.body` 根视图**（不是 `focusView` 内）：`focusView` 随 rootMode 切换被整体重建，sheet 挂里面会在形态切换时被重新 present，导致 detents/圆角错乱。

### 4.4 跨模块调用态

`ModuleCoordinator`（单例）目前提供 `openFiles(at:title:)`：即便文件 Tab 被关，容器详情页点卷挂载仍能调起独立的文件浏览器 `FileCallView`（`Files/FilesView.swift`），它自带 model、预设路径、只读浏览，不碰单例与偏好。

---

## 5. 连接链路（最重要的底层机制）

### 5.1 三条物理隔离的 SSH 连接

| 连接 | 文件 | 服务对象 |
|---|---|---|
| `SharedSSHConnection` | `Core/Session/` | 系统终端（保活复用，重连最激进） |
| `DockerSSHConnection` | `Docker/Core/` | Docker 业务 + 容器 exec 终端 |
| `DatabaseSSHConnection` | `Database/Core/DatabaseService.swift` | 数据库业务命令 |

- 三者都实现 `@MainActor protocol SSHConnectionProviding`（`Settings/Terminal/TerminalSession.swift`）：`ensureConnected(force:)` / `openShell()` / `openExecShell(command:)` / `closeShell()` / `disconnect()`。终端会话只依赖协议，注入不同连接即可服务不同场景（系统终端 vs 容器终端）。
- Docker / Database 连接遵循同一模板：`ensureConnected` 合并并发连接任务、按 `connectedServerID` 判复用、`performConnect` 读钥匙串凭据 → 建 `SSHSession` → 探测权限 → 替换旧 session。切换服务器或主动断开时重建。
- **权限探测** `detectPrivilege`：`id -u`==0 → `.root`；否则 `sudo -n true` 成功 → `.sudo`；否则 `.none`。结果按 `shared.privilege.<serverID>` 缓存到 UserDefaults。业务命令经 `run()` 自动加 `sudo -n` 前缀。
- 服务器上下文：`ServerSession`（根 Core）暴露 `defaultServer` / `currentServer`，具体 provider 由 `SettingsServerSession.install()` 注入。临时切换只影响当前进程，不落盘。

### 5.2 命令通道

`Core/SSH/SSHClient.swift` 的 `SSHSession.execute` 是并发安全的**注册表广播**（非单槽位）：`gateRegistry` 管理在途请求；关连接时 `failAll()` 打断所有在途命令——这正是必须隔离连接的原因。`ExecCollector` 遇 `ExitStatus` 会延迟约 400ms settle + 空输出重试，修复 `exit=0` 但 stdout 为空的竞态。

---

## 6. 各模块现状与核心文件

### 6.1 终端（底座，非模块）— 完整

- `Settings/Terminal/TerminalSession.swift`：全局单例会话，持有交互式 shell，字节级收发。
  - `TerminalByteBridge`：线程安全字节桥 + 256KB 环形缓冲，支持视图重建回放。**`reset()` 只清 buffer，绝不重置 `viewReady`**——这是"终端空壳"真因（若打回 false，`markReady()` 一次性守卫会让开 shell 晚于视图就绪时所有字节只进缓存不落地）。
  - `openTask` 合并开 shell 任务，杜绝双 shell 竞争；`generation` 区分意外断开与主动关闭；自动重连 + 本地欢迎横幅。
- `Settings/Terminal/TerminalView.swift`：SwiftTerm 终端仿真；右上角统一圆形箭头重连；Ctrl 展开第三项 Ctrl+L 清屏（byte 0x0C）。
- 悬浮终端 FAB 在 `ContentView.swift`：可拖动定位、`@AppStorage` 持久化、松手吸附左右边缘。**拖动中用纯内存态 `fabLiveOffset`，绝不逐帧写 AppStorage**（逐帧落盘 + 全视图重建是剧烈抖动的根因）；松手一次性写盘 + spring 动画。

### 6.2 文件 — 完整（对齐系统"文件"App）

`Files/`：SFTP v3 客户端与协议自实现（零额外依赖）+ SSH 命令回退。核心：
- `Core/SFTPClient.swift`、`Core/SFTPProtocol.swift`：移动用 `SSH_FXP_RENAME`，复制/粘贴 read+write 递归，删除优先 SSH `rm -rf`（失败回退纯 SFTP）。
- `Browser/FileBrowserModel.swift`、`FileBrowserView.swift`：导航栈底 = 默认目录（`DefaultDirectoryStore`），单例 model 跨 Tab 存活；`.searchable` 挂每一级目录页。
- `Detail/FileDetailView.swift`：信息面板读 `/etc/passwd`/`group` 显示可读属主；文件夹用 `du -sk` + `find` 测真实占用。
- `Editor/TextEditorView.swift`：≤2MB 纯文本编辑，写回远端并失效缓存。
- `Core/FileCache` 实际在根 `Core/Cache/FileCache.swift`：LRU 磁盘缓存，1GB 上限→淘汰到 800MB。
- `FileCallView`：跨模块调用态只读浏览器。

### 6.3 Docker — 完整（对标 1Panel）

`Docker/`：
- `Core/DockerService.swift`：`docker ps/stats/images/compose/inspect/logs/top/exec/kill/rm` 等命令封装；可用性用 `docker version` 探测。
- `Core/DockerSSHConnection.swift`：专用连接 + 容器 exec 终端。
- `Containers/`：列表（顶部方形统计卡片可点筛选，再点回全部；**已删除下方胶囊筛选排**）、卡片、双环 CPU/内存、详情页（按状态收敛按钮：running=停止/暂停/重启，paused=恢复/重启，stopped=启动；暂停/停止态禁用终端）、日志页、卷挂载点击 → `ModuleCoordinator.openFiles`。
- `Images/`、`Compose/`：镜像、Compose 分段。

### 6.4 数据库 — 新增，持续打磨闭环中（对标 1Panel）

`Database/`：**管理主体是"容器内的数据库"**，远程数据库只是其中一种来源。
- `Core/DatabaseModels.swift`：`DatabaseKind`（mysql/mariadb/postgresql/mongodb/redis）、`DatabaseConnection`（含 `source`/`containerID`/`inlinePassword`/`containerClient`）、`DatabaseConnectionStore`、`DatabaseItem`、`QueryResult`、`ContainerCredentialStore`（按容器 ID 持久化改密后的口令覆盖层）。
- `Core/DatabaseService.swift`：
  - `discoverContainerDatabases()`：`docker ps -a` 发现数据库容器，读容器环境变量取凭据（MySQL 用 root、`MARIADB_*`/`MYSQL_*` 系列），`detectClientCommand` 用 `command -v` 探测容器内真实客户端名（mysql/mariadb、mongosh/mongo、psql、redis-cli），命令走 `docker exec`，不依赖端口映射。
  - 库管理：`listDatabases`（过滤系统库）、`createDatabase`、**`createDatabaseWithUser`（一步到位建库+建专属用户+授权，默认仅授权该库）**、`dropDatabase`、`renameDatabase`。
  - 用户管理：`listUsers`、`createUser`、`deleteUser`、`changeUserPassword`、`resetAdminPassword`（改密后写凭据覆盖层，闭环）。
  - 数据浏览：`listTables`、`previewData`、`execute`、`listRedisValue`；输出解析 TSV/JSON/Redis。
  - 命令构造：`mysqlBase(conn, database:)` / `psqlBase` / `redisBase(conn, overridePassword:)` / `mongoClient`；管理命令不绑定默认库，`SHOW TABLES FROM \`库\`` 用全限定名；密码走 `MYSQL_PWD`/`PGPASSWORD`/`REDISCLI_AUTH`。
- `DatabaseView.swift`：顶部 segmented 切换「本地数据库 / 远程数据库」；进详情即列库并可增删改；详情页含「实例管理」区（改管理员密码 + 用户管理）；库列表点进 → `DatabaseBrowserView(fixedConnection:initialDatabase:)` 定位到该库。
- **Redis 特殊**：db 是固定索引（0–15），不支持建/删/改名库；改密用 `requirepass` + `CONFIG REWRITE`；用户管理走 ACL。

### 6.5 网站 — 空壳（待开发）

`Website/WebsiteView.swift` 目前只返回 `ModulePlaceholder`。下一步可做 PHP/Node/反向代理/证书/Nginx 编辑（目录占位已在早期 README 提及，但代码尚未实现）。

### 6.6 设置 — 完整

`Settings/`：服务器管理（列表、默认/当前标注、左滑编辑/删除、真实 SSH 测试连接、凭证存钥匙串）、缓存管理、终端偏好、`ModuleVisibility` 驱动模块管理卡片。**语言管理**见 `Settings/LanguageSettingsView.swift`（t1.66 新增，t1.68 增加 iCloud 同步开关）。

### 6.7 多语言机制（t1.66 新增，接手必读）

- **源语言 = 英文**：源码里所有 UI 字符串字面量已改为英文；显示点包 `L10n.t("English")`（`Core/Localization/L10n.swift`）。纯文案走查表，含插值的动态串保留 `\(...)` 结构直接写英文模板（**不能包 L10n.t**，插值在编译期求值成动态值，当 key 查不到）。
- **内核** `Core/Localization/LocalizationStore.swift`：单例，查表（key=英文，value=当前语言译文，查不到回退英文）、切换、导入导出、iCloud 降级。`revision` 驱动 `ContentView` 根 `.id()`，切语言立即重建生效。
- **内置包** `BuiltinPacks.swift`：英文包 identity（key 即 value），中文包 `[英文:中文]` 约 500 条。新增文案务必同步补中文包，否则中文环境显示英文（自查项）。
- **用户包（Telegram 式）**：JSON 结构 `{id,name,version,strings:{英文:译文}}`。设置→语言 可导入/导出/删除。导出英文模板 = 让用户自己翻译成任意语言再导回。自定义包 id 不能是 `en`/`zh-Hans`。
- **iCloud 优雅降级**：偏好（当前语言）走 `NSUbiquitousKeyValueStore`，自定义包镜像到 iCloud Drive 容器。侧载/免费签（Personal Team 无 iCloud capability）时 `ubiquityIdentityToken=nil`，全部自动退回本地 Documents/UserDefaults，**绝不崩溃**。上架（付费账号 + capability）后自动生效，无需改代码。
- **改动铁律**：`DatabaseService` 里两条 SQL 的 `'管理员'/'普通用户'` 是查询返回值，**绝不能翻译**；`contains("Stopped")` 等状态判断的比较值已随文案一起英文化，改一处要改全。

---

## 7. 设计规范（UI / 交互）

- 全部 SwiftUI + iOS 26 Liquid Glass；支持 Dynamic Type；列表/卡片尽量用系统原生组件（List insetGrouped、NavigationStack、`.searchable`、系统 alert），少造自定义控件。
- 卡片背景明显、左色条内缩卡片内、运行中/暂停中/已 stopped 状态配色一致；资源环用双环（CPU/内存）。
- 系统级行为能利用就利用：如 TabView 嵌套 NavigationStack 的"点当前 Tab 回栈底"由系统 pop 实现，不写对抗系统的补丁代码。
- 中文为主；`Localizable.xcstrings` 支持中英随系统切换（早期已建）。
- 涉及金额/涨跌的场景遵循中国习惯（涨红跌绿、¥ 符号）——本项目当前无金融场景，记此备用。

---

## 8. 构建、验证与发版流程（接手必读）

### 8.1 本地无 Swift 工具链

沙箱环境**没有 `swiftc`/Xcode**，无法本地编译。**任何代码改动必须交给 CI 编译验证**，不要声称"本地能编译"。静态检查靠 `grep`/`Read` 核对符号与语法。

### 8.2 推送方式（git push 曾因 TLS/认证失败）

用 GitHub Git Database API 推代码（脚本模板见 `/tmp/push_t*.py`，token 在 `/tmp/gh_token`）：
1. `GET /repos/ying-zi/LonePanel/tags` 取基线 tag 的 commit → `GET /git/commits/<sha>` 拿 tree。
2. 对**本次真正改动的文件**：`POST /git/blobs`（content=utf-8）→ 收集 tree_entries。
3. `POST /git/trees`（base_tree=基线 tree）→ `POST /git/commits`（parents=[基线 sha]）。
4. `PATCH /git/refs/heads/feature/module-architecture`（force）更新分支。
5. `POST /git/refs` 创建新 tag（如 `t1.64.0`）→ 触发 CI。
   - 覆盖已存在的 tag：先 `PATCH /git/refs/tags/<tag>`（force）。

> 注意：工作区是累积状态，`git diff` 会包含已推送的历史改动。**只推送本次改动的少数文件**，用 base_tree 继承其余文件，避免把未验证的本地残留带进去。新增文件还需手动改 `LonePanel.xcodeproj/project.pbxproj`（加 FileReference + Group children + Sources build file），否则不参与编译。

### 8.3 CI

`.github/workflows/build.yml`：推 `t*`/`v*` tag 触发，`macos-26`（Xcode 26 / iOS 26 SDK）构建：
- `t1.2.3` → version `1.2.3`，channel `testing`，pre-release；`v*` → 正式 release。
- build number = `git rev-list --count HEAD`（可复现）。
- 产物：`LonePanel-<version>-<UTC时间>-<channel>-unsigned.ipa`，发布到 GitHub Release，同时上传 artifact（保留 30 天）。
- CI 会校验 Info.plist 的 `CFBundleShortVersionString` 与 tag 一致，不一致直接失败。

### 8.4 等待构建 & 下载 IPA

```bash
# 轮询 workflow runs，按 tag 指向的 SHA 精确匹配（避免抓到旧 run）
# 构建成功后下载 release asset（urllib + Accept: application/octet-stream + 重试）
# curl 走 release download 偶尔 SSL/超时，asset API 通道更稳
unzip -t /workspace/LonePanel-<ver>-testing-unsigned.ipa | tail -2   # zip 校验
```
产物落地 `/workspace/`，用 `present_files` 交付给用户。脚本模板：`/tmp/wait_t*.py`（按 `TAG` 和输出路径 sed 生成新版本）。

### 8.5 迭代记录（tag → 主题）

| tag | 主题 |
|---|---|
| t1.48–t1.52 | Docker UI 打磨、工具型 App 形态、模块化底座阶段一 |
| t1.53–t1.55 | 终端连接可靠性、统一重连、终端下沉为底座、移除终端开关 |
| t1.56–t1.57 | 单模块 FAB 显示、拖动定位、设置卡片收起、数据库首版 |
| t1.58 | 设置卡片宿主修复、数据库对齐 1Panel（容器实例为主） |
| t1.59 | 容器首页筛选精简、数据库顶部切换、FAB 拖动去抖 |
| t1.60 | 单→多模块底部 Tab 显现、详情页列库+增删改 |
| t1.61 | MariaDB 客户端名探测 + MARIADB_* 凭据兼容 |
| t1.62 | 修复读不出已建库（root 凭据/去 -D/系统库过滤）+ 改管理员密码 + 用户管理 |
| t1.63 | 建库一步到位：建库同时建专属用户并授权该库 |
| t1.64 | 创建容器对标 1Panel + 文件调用态支持目录选择回传 |
| t1.65 | 容器首页工具栏统一搜索+更多；修复选目录后新建容器表单被收起 |
| **t1.66** | **多语言：默认英文 + 内置中文包 + Telegram式JSON语言包导入导出 + iCloud优雅降级；源码全量英文化（显示点走L10n.t查表）；终端欢迎语只保留连接行** |
| **t1.67** | **补齐多语言遗漏：alert 标题 / 带参确认弹窗 / 错误信息全部接入 L10n 查表；修复语言包导出（UIActivityViewController 改为宿主 present）** |
| **t1.68** | **修复 t1.67 闪退（L10n.f 的 String(format:)+%@ 传 Swift String 崩溃，改为纯字符串替换）；设置页新增 iCloud 同步开关** |
| **t1.70** | **修复切换中文闪退：把 .id(revision) 的内层子树与承载 sheet 的根容器分成两层（稳定 ZStack 根 + contentArea 子视图），换语言只重建内容区、sheet 宿主身份不变；bump dispatch 到下一 runloop，避开视图更新事务内换身份** |

---

## 9. 踩坑清单（别重复踩）

| 现象 | 根因 / 正解 |
|---|---|
| 编译报错 `CodingKeys` 无 `inlinePassword` | 新增内存态字段要加入 `init(from:)` 手动赋值，但故意不进 CodingKeys（不落盘） |
| iOS 26 SDK 下 `Section("标题"){ }footer:` 报错 | 改用 `Section { } header: { } footer: { }` |
| Swift 把 JS 回调变量 `c` 当字符串插值 | `jsString(old + "." + c)` 里 `c` 是 JS 变量，要在 JS 侧拼接，别放 Swift `\(...)` |
| `LabeledContent` 泛型推断失败 | 三元 String 会被当 ViewBuilder 闭包，用 `Text(...)` 包裹 label/value |
| 终端空壳（连上无输出） | `TerminalByteBridge.reset()` 不能重置 `viewReady`（见 6.1） |
| 容器列表极不稳定 | 终端与 Docker 共用连接，被重连 `failAll()` 打断 → 必须物理隔离 |
| `exit=0` 但 stdout 空 | ExecCollector 未等 ExitStatus；延迟 settle + 空输出重试 |
| `mariadb:11.8.6` 报 `mysql: not found` | 镜像客户端叫 `mariadb`；发现时 `command -v` 探测真实客户端名 |
| 设置卡片从终端兜底进单模块时错乱 | set sheet 挂在随 rootMode 重建的 `focusView` 内；上移到 body 根视图 |
| FAB 拖动剧烈闪烁 | 逐帧写 `@AppStorage`；改内存态实时位移，松手一次性落盘 |
| `sudo: command: command not found` | 探测 Docker 用 `docker version`，别用 `sudo docker` |
| git push TLS/认证失败 | 用 GitHub Git Database API（见 8.2） |
| 下载 IPA 超时 / RemoteDisconnected | 用 asset API（`/repos/{o}/{r}/releases/assets/{id}`）+ `Accept: application/octet-stream` + 分块读取 + urllib 重试 |
| **t1.67 闪退（编译过但运行崩）** | `String(format:)` 用 `%@` 传 Swift `String` 会 EXC_BAD_ACCESS（须 NSString）。本地化带参文案改用 `L10n.f` 的**纯 `replacingOccurrences` 替换**（`%@` 顺序 / `%1$@` 指定位置），彻底不用 `String(format:)`。**以后任何带参本地化都别用 String(format:)**。 |
| 选完目录返回后上层表单 sheet 被收起 | 调用方本身是 sheet 时，别用根视图的全局 `fileOpenTarget` 弹 sheet（祖先弹 sheet 会收起后代 sheet）；改用 `directoryPickTarget` + 本地 `.folderPicker(item:)` 形成正确嵌套 |
| **切换中文就闪退** | `.id(localization.revision)` 挂在 body 根链上（该链还挂着设置/终端/调用态三个 `.sheet`）。换语言 revision+1 → 整条根链换身份 → 正在显示的 sheet 宿主被销毁重建 → 重新 present 崩溃。**正解：引入稳定 ZStack 根容器承载全部 sheet，`.id(revision)` 只挂在它的子视图 `contentArea` 上**——注意计算属性会内联，仅把 .id 移进 `contentArea` 而不加稳定根容器是**无效**的（展开后结构不变）；且 `revision` 自增用 `DispatchQueue.main.async` 推到下一 runloop，绝不在 Picker/Toggle 的 set（视图更新事务）内同步改身份。 |

---

## 10. 接手指南：常见任务怎么干

1. **改/加数据库能力**：改 `Database/Core/DatabaseService.swift` 命令构造 + `DatabaseView.swift` UI；四种类型都要分支适配；密码走环境变量；新增文件记得改 pbxproj；**必须走 CI 验证**；用新 tag 发版。
2. **新增一个可插拔模块**：建 `<Name>/<Name>Tab.swift`（导出 `TabModule`）+ View；在 `TabRegistry.modules` 加一行；如需开关，`ModuleID` 加 case（`isCore=false`）；如需设置项，填 `settingsSection`。删模块反过来即可。
3. **加悬浮终端的宿主模块**：在模块 TabModule 里设 `showsFloatingTerminal: true`。
4. **改终端行为**：动 `TerminalSession` / `TerminalView` 前，先读 6.1 与踩坑表；终端是底座，任何"模块级终端开关"都不能加。
5. **发版**：本地改完 → API 推送 → 新 `t*` tag → 等 CI → asset API 下载 → zip 校验 → `present_files` 交付。**版本号按 t1.N+1.0 递增**（当前下一个是 t1.71.0）。

### 当前待办 / 方向（供参考）

- 网站模块仍是空壳，是下一个大模块候选（PHP / Node / 反向代理 / 证书 / Nginx 编辑器）。
- 数据库需继续真机验证各镜像的账号 host / 权限模型差异，按反馈适配。
- 持续按"闭环、自助"标准审查每个功能：建库能否直接用新账号连接、改密后能否当次会话无缝继续、删除是否级联清理等。

---

*最后更新：2026-11-26，基线 t1.70.0。文档随版本演进同步更新。*
