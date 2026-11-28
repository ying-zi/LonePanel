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
| 当前基线 | tag `t1.90.2`，版本 1.90.2（详见第 8.5 节） |

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

### 4.4 跨模块调用态 = 通用能力路由总线（网站联动地基，t1.77 定型）

`ModuleCoordinator`（单例，`App/TabRegistry.swift`）是**所有跨模块互调的唯一通道**。它用统一的 `ModuleCall` 枚举做分发，新增能力只加一个 case：

```
ModuleCall
├─ .files(FileOpenTarget)          → FileCallView          （文件浏览/选目录）
└─ .containerDetail(ContainerOpenTarget) → ContainerCallView（容器详情，t1.77 新增）
```

- `@Published var activeCall: ModuleCall?` 是唯一出口；`ContentView` 只挂一个 `.sheet(item: $coordinator.activeCall) { call in call.callView... }`。
- **视图分派内聚（t1.78）：**`ModuleCall.callView`（`@ViewBuilder`）把 case→视图映射收在类型自身，`ContentView` 分派永远是一行 `call.callView`，**App 核心零改动**。刻意不用运行时字符串注册表——那会丢失 Swift enum 的编译期穷举检查（漏注册=空白视图），稳定性优先下不可接受。
- `fileOpenTarget` 保留为**计算属性**（读写映射到 `.files` case），旧调用方零改动兼容。
- **新增能力标准两步**：① 在 `ModuleCoordinator` 加 `XxxOpenTarget` + `openXxx(...)` API（不检查模块开关=关入口不关能力）；② 在 `ModuleCall` 加一个 case + `callView` 里加一个分支。调用方永远只依赖 `ModuleCoordinator` 类型，不引用目标模块的视图/模型，`ContentView` 不动。

**事件钩子 `AppEventBus`（t1.78 新增，与能力钩子配套的第二类系统级原语）**：
- `Core/Session/AppEventBus.swift`，`enum AppEvent` 类型化事件（`.serverChanged(epoch:)` / `.containersChanged`），新增事件只加 case，编译期穷举。
- `emit(_:)` 统一切主线程投递；订阅用 `.onReceive(AppEventBus.shared.serverChanges())` / `.containerChanges()`。
- **切服刷新闭环**：`ServerSession.refresh()` 在 epoch 递增时广播 `.serverChanged`，容器/镜像/Compose/容器调用态四个视图订阅后清空旧数据并重载——修复"切服后容器模块不自动刷新"（对应阶段 0 遗留 P1）。新模块只要"按当前服务器加载数据"，订阅 `serverChanges()` 一行即可自动跟随切服，不再各自观察 `currentServer`。
- **变更广播**：`DockerService.mutate()` 成功时广播 `.containersChanged`，为网站联动（如反代关联容器状态变化后刷新）预留订阅点。

**已落地的调用态**：
- `FileOpenTarget.capability`（t1.78.1 新增）定义文件能力等级，调用方**声明需要哪种能力**，文件模块据此呈现对应 UI——这是"钩子暴露能力"的落点：
  - `.select`（`pickDirectory(...)` / `directoryPickTarget(...)`）→ `FileCallView`：目录选择，逐层浏览器 + **逐级返回**（`goBack()`，`pathStack` 出栈；顶层才是取消）+「选择此目录」回传。供数据库/网站备份选目录。**修复了进入子目录后无法返回上一级的 bug**。
  - `.browse`（`openFiles(at:title:)`）→ `FileCallView`：只读浏览，左上角有层级时返回、右上角收起。
  - `.manage`（`manageFiles(at:title:)`）→ `FileManageCallView`（`Files/`）：**复用入口态完整 `FileBrowserView`**，天然具备新建/编辑/删除/上传/压缩/粘贴 + 系统原生逐级返回。供容器卷挂载点（宿主机真实目录）操作文件。用独立 `FileBrowserModel`（`isCallInstance=true` 禁写全局偏好、`callRootPath` 指定挂载点为栈底）。
  - `FileBrowserView` 加 `init(model:callClose:)` 注入点 + `callClose` 关闭按钮（透传给 DirectoryPage）：入口态零影响，调用态复用全部 UI。
- `openContainerDetail(id:title:)` → `ContainerCallView`（`Docker/Containers/`）：按容器 ID 在**当前服务器**拉真实容器，复用 `ContainerDetailView`。**这是为网站反代关联容器预留的接口**——网站模块拿到关联容器 ID 后直接调它，无需认识容器模块内部。

**调用态铁律**（严格遵守，否则联动出乱子）：独立 Model 实例（不碰 shared）、不注入设置齿轮、不读写偏好（`isCallInstance` 强制）、看完即走。所有调用态的连接加载都走带 epoch 校验的连接层（见 5.1），保证打开的是**当前服务器**的资源，不会串到切服前的旧机器。文件能力按 `capability` 分级复用，**不要为每种场景复制一套视图**。

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
- **连接代次 `ServerSession.connectionEpoch`（t1.77 新增，跨模块联动地基）**：`currentServer` 每次实质变化（临时切换/改默认/删服/编辑当前服），`refresh()` 都递增 epoch。四条连接（Shared/Docker/Database/FileBrowser）各自记 `connectedEpoch`，`ensureConnected` 复用前必须 `connectedEpoch == connectionEpoch`，否则强制重建；`TerminalSession` 记 `shellEpoch`，`ensureAlive` 短路前比对，变了就关旧 shell 并 force 重连。**这解决了"切服后终端/调用态仍操作旧服务器"的硬伤**——网站反代→容器详情等联动正确性的前提。新增连接层/联动模块务必沿用 epoch 校验。
- **事件钩子 `AppEventBus`（t1.78）**：epoch 只解决"连接重建"，但视图层的"何时重新拉数据"需要事件驱动。`ServerSession.refresh()` 在 epoch 递增时同步广播 `.serverChanged(epoch:)`，所有按当前服务器加载的视图订阅 `serverChanges()` 即自动重载（容器/镜像/Compose/容器调用态已接入）。两条机制分工：**epoch 保证连接正确，事件保证数据及时**；新模块两者都要用。详见 4.4。

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
- **内核** `Core/Localization/LocalizationStore.swift`：单例，查表（key=英文，value=当前语言译文，查不到回退英文）、切换、导入导出、iCloud 降级。**切换即时生效**（t1.74 恢复）：`currentID` 即查表 key，切时当前包身份一变，所有 `L10n.t` 下一帧读新译文；`scheduleBump()` 只把 `revision` 下一 runloop 自增作轻量刷新信号，**不用 `.id()` 重建视图树**（t1.71/t1.72 曾因重建触发字典懒初始化重复 key 崩溃，已根治）。
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
- **图形语义铁律（t1.90.1 用户定、t1.90.2 补全取消，勿混用）**：能用通用图形表达就别用文字按钮，既统一交互又减少翻译文本。三个统一组件在 `TabModule.swift`：✓ **`DoneCheckmarkButton`（checkmark）= 操作完成 / 确认 / 选中**（调用态详情看完、多选完成、输入完成）；⌄ **`DismissChevronButton`（chevron.down）= 收起 / 折叠面板**（诊断、日志、终端、文件调用态 sheet 纯关闭）；✕ **`CancelXButton`（xmark）= 放弃表单操作**（sheet/表单左上角的取消，全 App 20 处已替换）。同类操作全 App 必须同款图形。**例外**：alert 确认弹窗里的标准「取消」保留文字（`role: .cancel`，iOS HIG，21 处未动）。t1.90.0 曾把 Done 误用 chevron.down，t1.90.1 已纠正。
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
| **t1.71** | **切换中文闪退根治：改为「重启后生效」——拆分生效语言 currentID（启动锁定、运行期恒定）与待选 selectedID（Picker 绑定、只持久化）；彻底移除 revision / .id 视图重建机制，切换时不重算任何文案、不重建任何视图树** |
| **t1.72** | **真正根治切中文闪退：崩溃日志定位到 EXC_BREAKPOINT/brk 1 来自 Swift 静态字典 `BuiltinPacks.zhHans` 的懒初始化——Release 下编译器用 `Dictionary(uniqueKeysWithValues:)`，遇 15 个重复 key 触发 preconditionFailure。删除全部重复 key，并把字典改为运行期逐条下标赋值构建，彻底根除 trap** |
| **t1.73** | **修复中英混合双打：中文包 546 条翻译齐全但 179 处 UI 文案从没接 L10n.t()（TextField/LabeledContent/navigationTitle/Tab标题/enum rawValue/Service层错误信息等）。批量把 342 处展示文案接上 L10n.t()，排除 JSON 字典 key、enum rawValue 定义、SF Symbol、命令串；补 Docker/Compose/CPU 3 条译文** |
| **t1.74** | **①统一关闭按钮：全 App sheet/popover 的 Done 按钮改为右上角 chevron.down 图形按钮（新 DismissChevronButton），与复制/更多按钮连成胶囊，少一项翻译；②补插值/LogRange/重置密码等剩余未翻译文案；③修复翻译模板导出（UIActivityViewController 直接作 sheet root，旧「空VC+present」静默失败）；④恢复即时切换语言（崩根字典已除，重启提示机制整套移除）；⑤修终端键盘菜单中文：developmentRegion 改回 en** |
| **t1.75** | **①翻译模板导出彻底修复：不再把 UIActivityViewController 当 SwiftUI sheet root，改为 SharePresenter 找 keyWindow 顶层 VC 直接 present；②底部 Tab 标题切语言即时生效：TabModule.title 改存英文 key，展示点统一 L10n.t（static let 首次求值固化的坑）；③终端编辑菜单本地化：method swizzling 替换 SwiftTerm 1.2.1 的 canPerformAction（public 非 open 无法 override），屏蔽系统英文标准项，willShowMenu 塞入走 L10n 的中文 UIMenuItem；④容器运行时长「多一个 s」修复：单位替换不再拿译文当搜索 key，复数优先；⑤补排序菜单选中项 Name 走 L10n、中文包补 Paste=粘贴；⑥单模块右上角 UI 统一：文件页把 ⋯+齿轮从手写 HStack 拆成独立 ToolbarItem，与 Docker/数据库/终端一致由系统排胶囊** |
| **t1.76** | **①终端复制粘贴菜单「全没了」致命回归修复：t1.75 的 method swizzling 全局替换 canPerformAction 把系统标准项全屏蔽、自定义项又没挂上导致菜单空白；先尝试 override editMenu 但 SwiftTerm 1.2.1 父类无可 override 的 editMenu 属性（编译失败 error: property does not override），最终彻底回退——完全不碰菜单，用 SwiftTerm 原生系统菜单（英文但复制粘贴功能 100% 恢复）。系统编辑菜单标题跟随 developmentRegion 是系统级限制，App 内切语言改不了，本地化菜单留到项目收尾再评估；②删除自定义语言包确认弹窗 confirmationDialog（iPad 带错位箭头的 popover）改普通居中 alert；③容器日志页右上角 ⋯+关闭从手写 HStack 拆成独立 ToolbarItem，间距与其他页统一；④文件模块日期显示跟随 App 内语言（新增 L10n.currentLocale/dateTimeText，DateFormatter medium 含时分秒）而非系统 locale，列表与详情统一；⑤新增文件压缩/解压：model 走远端 tar/unzip/7z/rar 命令，contextMenu 与多选工具条加入口，压缩包名输入 + 解压确认弹窗，含中文翻译** |
| **t1.76.1** | **修复压缩失败（tar: xxx: Cannot stat: No such file or directory）：compress 里 -C 误切到父目录，但源项是相对当前目录的 basename，导致 tar 在父目录找不到文件。改为 -C 当前目录；产物用绝对路径写到当前目录，因明确列出 basename（非 "."）不会把归档自身打进去** |
| **t1.76.2** | **①压缩支持格式选择：新增 ArchiveFormat(.tar.gz/.zip)，压缩参数表独立 sheet（CompressSheet，alert 里放 Picker 不可靠），model 按格式走 tar -czf 或 zip -r，自动去旧后缀按所选格式补；②自定义语言包删除后重启复活修复：removePack 只从内存数组删+persistCustomPacks（只写存活包、从不删文件），磁盘 JSON 和 iCloud 镜像都没删，重启 loadLocal 又读回。改为显式删除本地 + iCloud 的 <id>.json** |
| **t1.76.3** | **①压缩后缀误解修复：compressTarget 默认名不再塞 .tar.gz（只填主名），CompressSheet 把格式从独立 segmented 改为紧贴名称框右侧的后缀下拉 Menu（网页款式，.borderlessButton，原生不冲突），并用 LabeledContent 实时预览最终完整文件名（finalName 去旧后缀+拼当前格式），选 zip 立即显示 .zip，消除误解；②Docker 顶部 tab「图像」改「镜像」：d["Image"] 由「图像」改「镜像」（影响 Docker tab/容器详情/数据库实例 3 处正确语境），文件详情页图片类型分流到新 key d["Picture"]=「图像」，避免误伤** |
| **t1.76.5** | **设置页模块管理列表的模块名（Website/Docker/Database/Files）切中文不翻译：SettingsView.moduleToggleRow 里 Label(item.title) 直接用英文 key（TabRegistry.module.title 存英文 key，Tab 栏展示时走 L10n.t，但设置页漏了），改为 Label(L10n.t(item.title))。注：t1.76.4 因 GitHub Actions force-update tag 复用旧 ref 上下文导致 asset 上传错位，改用全新 tag 规避** |
| **t1.77.0** | **阶段 0 稳定性清理 + 跨模块联动地基。P0：①Redis 命令 quote——原始命令逐 token quote（新增 quoteRedisArgs），ACL SETUSER 的 `>pass`/`~*`/`&*`/`+@all` 逐个整体 quote（旧代码 `>` 被 shell 当重定向、口令写进文件，功能完全不可用）；②SFTP 移动软链数据丢失——copyItem 返回"是否保真复制"，含软链时返回 false，move 回退绝不删源、抛错交给上层 shell mv。P1：③连接代次 ServerSession.connectionEpoch——切服/删服/编辑后四条连接+终端统一失效重建，解决"切服仍操作旧服务器"（跨模块联动地基）；④FileCache 覆盖写自删——同 key 同扩展名新旧路径相同，删除旧路径时跳过；⑤SSHSession.close 幂等+异步 shutdown——消除 deinit 二次关闭与 event loop 线程同步死锁；⑥Docker/Database 错误反馈全线补齐——容器详情/列表/Compose/镜像/日志操作失败都出 alert，mutate 失败不再误报成功，parseLogs 不再把错误当日志，loadTables 失败不再吞成空；⑦数据库成功消息本地化。地基：ModuleCoordinator 升级为通用 ModuleCall 路由总线，新增 openContainerDetail + ContainerCallView（网站反代→容器详情接口），fileOpenTarget 计算属性兼容旧代码** |
| **t1.78.0** | **阶段 0.5 钩子地基完善 + 切服容器刷新修复。①事件钩子 AppEventBus（Core/Session）：类型化 enum AppEvent（serverChanged/containersChanged）+ emit 统一主线程投递 + serverChanges()/containerChanges() 便捷订阅；②ServerSession.refresh 在 epoch 递增时广播 serverChanged，容器/镜像/Compose/容器调用态四视图订阅后清空旧数据重载——修复用户实测「切服后容器模块不自动刷新」，新模块按当前服务器加载数据只需订阅一行；③DockerService.mutate 成功广播 containersChanged，为网站反代联动预留订阅点；④能力总线的视图分派内聚到 ModuleCall.callView，ContentView 分派简化为一行、App 核心零改动，刻意保留 enum 编译期穷举检查（不用运行时注册表避免漏注册空白视图）。** |
| **t1.78.1** | **文件调用态能力分级 + 目录返回修复。①修复目录选择模式进入子目录后无法返回上一级：FileCallView 加 goBack()，`pathStack` 出栈，左上角顶层显示取消/子层显示返回（select/browse 两档都有）；②FileOpenTarget 新增 FileCallCapability(.select/.browse/.manage) 能力等级——调用方声明能力、文件模块按级呈现（钩子暴露能力的落点）；③容器卷挂载点改用 manageFiles → FileManageCallView，复用入口态完整 FileBrowserView（新建/编辑/删除/上传/压缩/粘贴 + 系统原生返回），因卷是宿主机真实目录须允许操作；④FileBrowserView 加 init(model:callClose:) 注入点 + callClose 关闭按钮透传 DirectoryPage；⑤FileBrowserModel 加 isCallInstance(禁写全局偏好)/callRootPath(指定挂载点栈底)。** |
| **t1.79.0** | **阶段 1 镜像管理增强（对标 1Panel）。镜像页从「只有列表 + 删除」补齐四能力：①拉取镜像（复用已有 DockerService.pullImage，输入完整引用，180s 超时，进度态）；②打标签（新增 tagImage→docker tag，仓库名/tag 格式校验 + ShellQuote.quote）；③导出镜像（新增 exportImage→docker save -o，复用 `directoryPickTarget`+本地 `.folderPicker` 选服务器目录，文件名自动补全 .tar/.tar.gz，文件名去路径分隔符防逃逸）；④导入镜像（新增 importImage→docker load -i，选目录+文件名拼服务器绝对路径）。UI：行尾多个按钮收敛为单一「更多」菜单（打标签/导出/删除），全局拉取/导入放顶部 Section；四类操作统一一个 `ImageAction` sheet 出口；导入成功广播 containersChanged。ImageView 额外订阅 containerChanges 同步别处变更。所有失败给人话提示、成功短 toast，中文译文补齐，无重复 key。** |
| **t1.80.1** | **阶段 1 S1-04 网络 / 存储卷管理（对标 1Panel 容器-网络/卷）。新增 DockerNetworkRow/DockerVolumeRow 解析模型 + DockerNetwork/DockerVolume 展示模型（Hashable）；DockerService 新增 fetchNetworkList/createNetwork(network create，driver/subnet/gateway/isInternal/ipv6)/removeNetwork、fetchVolumeList/createVolume(volume create，允许空名随机生成)/removeVolume，全部经 DockerService.run（带 DockerSSHConnection epoch 校验），外部输入 ShellQuote.quote + validResourceName 校验，变更经 mutate 统一广播 containersChanged。新建 NetworkListView/VolumeListView（Docker/Networks 组，pbxproj 四处登记）：列表+搜索+创建 sheet+删除确认+错误 alert+成功 toast，订阅 serverChanges 切服清空重载、containerChanges 同步；系统网络 bridge/host/none 禁删并显示「系统」徽章。DockerView 分段扩为 5 段（容器/镜像/编排/网络/存储卷），Picker 改 maxWidth 360 自适应。新增中文译文 40+ key，无新增重复 key。** ⚠️ 编译坑二则：①`internal` 是 Swift 保留关键字，作参数标签/变量名/状态属性均报 `keyword 'internal' cannot be used as an identifier`（t1.80.0 CI 失败）→ 改名 `isInternal`；②SwiftUI `foregroundStyle(cond ? .secondary : .tint)` 三元分支类型不一致（`.secondary` 是 HierarchicalShapeStyle、`.tint` 是 TintShapeStyle）报 `member 'tint' ... expects HierarchicalShapeStyle`（t1.80.1 CI 失败）→ 显式 `Color.secondary : Color.accentColor`。均用 fresh tag 重发，最终 t1.80.2 通过。 |
| **t1.81.0** | **阶段 1 S1-05a 命令行创建容器 + Docker 顶部菜单汉堡化。① DockerService 新增 `createContainerFromCommand`：用户粘贴单条完整 docker run 命令原样执行——严格校验（禁换行/`;`/`|`/`` ` ``/`$()`/`&&`/`||`/`>`/`<` 拼接，必须以 docker run 开头、允许前导 sudo 剥离），经 run()（epoch 校验+重连重试），成功广播 containersChanged 并返回容器 ID；与「表单创建逐字段 quote」互补，命令行由用户对原文负责。② ContainerCreateView 加 `CreateMode`(.form/.commandLine) 分段：命令行模式提供 TextEditor 大文本框+占位提示+防误触说明，`canSubmit` 随模式切换校验，提交后复用 onCreated 定位新容器。③ 应用户要求，DockerView 顶部 5 段 Picker + 更多菜单全部收敛到左上角汉堡（`line.3.horizontal`）：分区切换（当前项打勾，用 `section == item ? "checkmark" : sectionSymbol(item)`）、容器专属操作（新建/视图切换）、诊断，标题栏中间预留；设置齿轮保留右上角不破坏入口态形态判断。④ S1-05 在追踪表拆为 a/b/c（命令行/编排模板/Registry）逐项交付。新增中文译文 11 key，无重复 key。** ⚠️ 编译坑：DockerView 内定义了 `enum Section`，会遮蔽 SwiftUI 的 `Section` 视图→菜单分组须显式写 `SwiftUI.Section { } header:`，否则报枚举无该初始化器。已在推送前静态审查规避。 |
| **t1.82.0** | **阶段 1 S1-05b 编排模板 + 顶部布局规则固化。① DockerService 新增 saveComposeFile(directory/projectName/yaml)：yml 走 base64 编码写入（避免 heredoc 注入），目录/项目名校验+quote，写 `<dir>/docker-compose.<name>.yml`；deployCompose(path/project)：`docker compose -f <path> -p <project> up -d`，成功广播 containersChanged。② DockerModels 新增 ComposeTemplate（5 个内置模板：nginx/redis/mysql/postgres/minio，精简 yml）。③ 新建 ComposeTemplateView（Compose 组，pbxproj 四处登记）：模板列表→编辑页（项目名/yml/选目录/部署），本页是 sheet 故用本地 .folderPicker 选服务器目录；部署两步（先写文件再 up）。④ ComposeListView 订阅 containerChanges 部署后自动刷新。⑤ **顶部操作逻辑固化（用户明确的统一规则）：左边=分类/筛选/返回，右边=所有操作+搜索**。据此把 t1.81.0 塞进左上角汉堡的「新建容器/视图切换/诊断」全部移回右上角；左上汉堡只剩分区切换（分类）。补中文译文 16 key，无重复 key。** ⚠️ 后续修正 t1.82.1：用户明确要求「右上角与文件模块完全一致」——文件模块右上角只有 ⋯ 更多菜单 + 设置齿轮（搜索由系统 .searchable 提供），所有操作都收在 ⋯ 里、不额外平铺图标。故把 t1.82.0 平铺的加号（新建容器）/视图切换/编排模板入口全部收进 ⋯ 菜单，主视图右上角仅剩 ⋯ + 设置两项 ToolbarItem。以后新增顶部操作一律进 ⋯，不再平铺。 |
| **t1.82.2** | **设置页底部新增版本信息 + 顶部修正落地。①SettingsView 的 List 末尾加「版本」Section：运行时从 Bundle 的 `CFBundleShortVersionString` + `CFBundleVersion` 读取，显示 `1.82.2 (95)`，可选中复制；CI 由 tag 注入这两个字段，故每次发版自动同步、无需手改代码（用户要求「设置页底部显示版本，每次推送自动更新」）。②AppVersion 辅助类型定义在 SettingsView.swift 同文件末尾（不新增 Swift 文件、不动 pbxproj）。③补中文译文 `Version footer`。含 t1.82.1 的顶部对齐修正（右上角与文件模块完全一致）。** |
| **t1.83.0** | **阶段 1 S1-05c 仓库 Registry——阶段 1 收官。** ①DockerService 新增 registryLogin（docker login -u/-p，server/user/password 校验 + ShellQuote.quote，密码禁空白避免打码残留）、registryLogout（docker logout）、listRegistryLogins（读 ~/.docker/config.json 的 auths 键）、validRegistryServer、insecureRegistryGuide（返回纯文本指引，绝不自动改 daemon.json/重启 Docker）。②**安全关键**：DockerDiagnostics.record 对 command/out/err 统一打码——正则匹配 `--password`/`-p` 后密码替换为 `******`，`-p` 仅在含 login 时打码避免误伤 `docker run -p` 端口映射；密码绝不明文进诊断面板或复制报告（技术债 D-05 落点）。③新建 RegistryView（Views 组，pbxproj 四处登记）：已登录仓库列表（可退出）+ 登录表单（密码可见切换）+ HTTP 不安全仓库手动配置指引 alert，作为 sheet 从 DockerView 更多菜单「仓库」入口进入。④**设计取舍**：SSH execute 不支持 stdin，故未用 --password-stdin，改用 -p + 诊断层打码；HTTP 仓库重启会中断容器，只给指引不自动执行。补中文译文 17 key，无重复 key。** |
| **t1.84.0** | **修复编排页右上角工具栏不统一。** 用户实测：切到编排页右上角结构与其他分区不一致——根因是 ComposeListView 是 Docker 五分区中唯一没有 `.searchable` 的页面。修复：ComposeListView 补 `@State searchText` + 按项目名过滤的 `filtered` + `.searchable(text:prompt:)` + `.searchToolbarBehavior(.minimize)`，空态区分「无项目/无匹配项目」；与容器/镜像/网络/卷四分区完全对齐。新增 2 个本地化 key（Search Compose projects / No matching Compose projects），zhHans + xcstrings 同步，无重复 key。** ⚠️ 教训：Docker 每个分区子视图都必须成对写 `.searchable` + `.searchToolbarBehavior(.minimize)`，漏一个就会在切换时右上角工具栏结构不一致——新增分区务必对照已有四分区检查。 |
| **t1.85.0** | **阶段 2 S2-01 Redis 配置与持久化完整化。** ①**修复中文环境改密码必失败 bug**：resetAdminPassword 的 Redis 分支用 `L10n.t("OK")` 判断 CONFIG SET 返回，中文包返回「确定」而 redis-cli 返回固定英文 `OK`，导致中文下永远判失败——改为固定英文 "OK" 匹配（协议返回非本地化文案，不能用 L10n）。② DatabaseService 新增三方法：`fetchRedisConfig`（CONFIG GET 固定白名单逐项读 + INFO ALL 状态解析 + 推断持久化模式；requirepass 只探测是否设置、绝不返回明文）、`setRedisPersistence`（RDB/AOF/none 切换，命令用固定字面量不接受外部输入，成功后尽力 CONFIG REWRITE）、`runRedisSave`（BGSAVE/BGREWRITEAOF 异步保存）。③ 新建 RedisConfigView（**放 DatabaseView.swift 同文件免改 pbxproj**）：状态摘要 + 持久化模式 Menu 切换（⋯ 收起、二次确认）+ 只读关键配置 + 顶部 ⋯ 放刷新/立即保存，InstanceAdminSection 加入口（仅 Redis 显示）。④ 新模型 RedisPersistenceMode/RedisConfigItem/RedisServerInfo/RedisConfigSnapshot 放 DatabaseModels.swift。新增中文译文 42 key，无重复 key。** ⚠️ 经验：redis-cli 协议返回（OK/PONG/ERROR）是固定英文，禁止用 L10n.t 匹配——本地化只用于展示文案，不用于解析机器输出。 |
| **t1.86.0** | **①修复编排模板 Redis 图标缺失 + ②阶段 2 S2-02 可视化数据浏览表结构查看。** ① 用户截图：ComposeTemplateView 内置模板列表里 Redis 行图标空白（symbol=`zap` 在该设备渲染为空）。修复：Redis symbol 改 `bolt.fill`，并加 `composeTemplateSymbol(_:)` 用 `UIImage(systemName:)` 探测、失效回退 `square.grid.2x2`，杜绝任何模板空白图标。② DatabaseService 新增 `fetchTableSchema`（MySQL DESCRIBE / PostgreSQL information_schema.columns / MongoDB 采样首文档字段类型 / Redis TYPE+TTL+ENCODING+MEMORY 元信息，复用 QueryResult 表格）；DataBrowserView 加「数据/结构」切换（⋯ 菜单）+ 双缓存避免重复加载；DatabaseBrowserView + DataBrowserView 右上角平铺按钮收进 ⋯（统一 UI 规范）。新增 4 个中文 key，无重复。** ⚠️ 经验：SF Symbol 名在不同 iOS 版本可能渲染为空白，图标位应加 `UIImage(systemName:) != nil` 兜底，尤其仅有单个模板/条目异常时优先怀疑符号名在该系统不可用。 |
| **t1.87.1** | **S1-06 容器转编排闭环（Docker 模块补完）。**（t1.87.0 CI 编译失败：ComposeDraft 未符合 Hashable，navigationDestination(item:) 要求 Hashable；fresh tag t1.87.1 补 Hashable 修复。） 用户三决策：单容器 / 环境变量明文 / 自动重命名。① DockerInspectInfo 扩展解析字段（容器名/命令/入口点/工作目录/user/hostname/networkMode/privileged/capAdd/labels/healthcheck，既有字段不动，详情页不受影响）；② 新增 ComposeDraft + ComposeGenerator（纯函数反向生成 yml：**刻意省略 container_name** → compose 以 `<project>-<service>-1` 命名新容器、从根上避免撞名；项目名 `<name>-compose`；环境变量明文 KEY:"value" 并转义；healthcheck/自定义网络等无法还原项写注释 + warnings）；③ DockerService.generateComposeDraft（读 inspect + 本地生成，纯能力，带 epoch 校验）；④ ComposeTemplateEditView 重构为通用 `ComposeEditorView`（模板/草稿共用，目录选择改为编辑器自承载 folderPicker，部署后导航全交 onDeployed，自身不 dismiss）；⑤ 容器详情入口「从该容器创建编排模板」用 **push**（navigationDestination(item:)），新增 `AppEvent.composeDeployed`+composeDeployments()，DockerView 收到后清导航栈+切编排分区+刷新。新增 11 个中文 key，无重复。**核心语义：以原容器为基础创建全新编排模板，非原地重编排——部署生成新容器，原容器不受影响。⚠️ 交互铁律：独立完整任务（编排/导出）用 push，完成后不需返回发起页；附属动作（选文件夹/选目录）才用 sheet，选完要带结果返回继续。 |
| **t1.88.0** | **修复编排栏目恒定为空 + 显示全部项目 + 左侧状态色条。** 用户实测：部署 MySQL/Nginx 模板后编排页始终空。根因：`fetchComposeProjects` 用 `docker compose ls --format json`，但该命令输出**单个 JSON 数组**（`[{...}]`），却套用了为 `docker ps --format '{{json .}}'`（每行一条 JSON）设计的 `decodeLines`——数组以 `[` 开头被整行跳过 → 恒定为空，且旧空态文案误称「旧版 docker-compose/版本过低可能不显示」掩盖真相。修复：① 命令加 `--all`（默认只列 running，已 down/created 项目会漏）；② 新增 `decodeComposeRows`：截取 `[...]` 按数组整体解析，兜底 JSON Lines，容忍混入告警；③ `DockerComposeProject` 加 `state` 计算属性（compose Status 文本 `running(1)`/`exited(0)`/`created`/`paused` → 复用容器三态，暂停橙/运行绿/其余灰）；④ ComposeListView 行改为与容器列表一致的卡片（ZStack + 左侧 `StatusStripe` + 状态文字按 `DockerStateStyle.color` 着色），订阅的 `containerChanges` 部署后照常刷新；⑤ 空态文案改为准确描述，BuiltinPacks + xcstrings 同步（无新增重复 key）。**⚠️ 教训：不同 docker 子命令 `--format json` 形态不同——`ps` 是 JSON Lines、`compose ls` 是单个数组，解析前务必确认真实输出，勿复用逐行解析器。 |
| **t1.89.0** | **容器模块交互梳理：编排闭环完善 + 创建入口统一 + 重建式编辑容器。** 用户在进入阶段 2 前要求全量梳理 Docker 交互，三项拍板：①**编排卡片**从三按钮平铺改为「按状态主操作（停→启动/跑→停止）+ ⋯（重启/详情）」+ 状态徽章，点卡片 push 详情页；②**创建入口统一**：镜像拉取/导入、网络/卷创建从各自列表顶部 Section 移到 DockerView 右上 ⋯，用 `AppEvent.dockerCreateRequest` + `dockerCreateRequests()` 事件解耦——父视图发事件、当前分区子视图订阅后弹自己的 sheet（onDone/toast 留子视图）；③**编排项目详情页** ComposeProjectDetailView（放 ComposeListView.swift 同文件免改 pbxproj）：项目概览 + 服务列表（`docker compose ps --format json` JSON Lines，点服务经 `ModuleCoordinator.openContainerDetail` 跳容器详情调用态）+ 编辑 yml（ComposeEditorView 加 `existingConfigPath` 覆盖原文件 + 重新 up）+ 启停/重启/删除项目（down + rm）。④**重建式编辑容器**（核心难点）：Docker 不允许原地改网络/端口/挂载/镜像，只能重建——用户拍板带回滚流程：`ContainerCreateSpec.from(inspect)` 反向预填表单（capAdd/user/healthcheck/匿名卷生成 warnings）、`DockerService.recreateContainer` 做「停→改名 backup→建同名新容器→成功删 backup / 失败回滚（删新+改名回+按需 start）」、`ContainerCreateView` 加 `EditContext` 编辑模式（隐藏命令行、锁定名称、顶部强警告 + 二次确认弹窗）、详情页加「编辑容器」入口。**⚠️ 关键认知：容器"编辑"= 重建同名容器，挂载卷数据保留、未挂载数据（如没挂出来的数据库目录）会丢——必须强警告。⚠️ compose ps 的 State 是 running/exited，与 docker ps 的 Up/Exited 不同，不能复用 DockerContainerState.from（按 hasPrefix("up") 判断），否则 running 被误判为停止。 |
| **t1.90.0** | **编排模块收敛为纯只读 + 右上角完成按钮统一。** 用户实测致命 bug：在编排页点「停止」后容器**彻底消失**、容器列表也看不到。根因：编排的"停止"走 `docker compose down`——**down = 停容器 + 删容器**（不是 stop），容器被删除；且 t1.89.0 编排卡片/详情页都暴露了启停/重启/删除/编辑 yml，重复容器页能力又危险。用户拍板：编排页**不控制容器启停、不放操作按钮，点列表只进详情页看**。① ComposeListView 列表卡片去掉主操作 + ⋯ 菜单，改为纯展示（色条 + 徽章 + 配置路径 + chevron）+ 整行点击进详情；② ComposeProjectDetailView 移除「项目操作」（启停/重启）、「删除项目」Section、编辑 yml 入口（ComposeEditPayload/navigationDestination/runAction/removeProject 及全部 alert/state），改为**只读**：项目概览 + 服务列表（点服务跳容器详情做启停）+ yml 内容只读展示（新增 key `Compose file content`）；③ Service 层 `composeAction`/`removeComposeProject`/`updateComposeFile` 保留为无调用能力（"关入口不关能力"，将来如需安全版重编排可直接复用）；④ 全 App 文字「操作已完成」(Done) 按钮清零（图形化）：ContainerCallView / TextEditorView 的 Done 改图形按钮。**⚠️ 此处图形选择 t1.90.0 一度误用 chevron.down，t1.90.1 已纠正为勾（checkmark）——详见版本历史与图形语义规范。** 其余关闭/收起早已统一为 chevron.down。**⚠️ 铁律：`docker compose down` 会删容器——编排页永远不暴露 down/stop；容器启停只在容器分区做。 |
| **t1.90.1** | **图形语义规范：完成用勾、收起用向下箭头（纠正 t1.90.0 的 Done 图形误用）。** 用户纠正：t1.90.0 把「操作已完成」(Done) 也改成了 chevron.down 是错误逻辑——**勾（✓）= 操作完成/确认，向下箭头（⌄）= 收起/折叠**，且「能用通用图形表达就别用文字」。① TabModule.swift 新增 `DoneCheckmarkButton`（checkmark / size 17 bold / .primary / 32×32，accessibility "Done"），样式与文件多选态右上角完成勾完全一致，与 `DismissChevronButton`（收起/关闭）分工明确；② ContainerCallView 调用态详情右上角 Done 由 chevron.down 改用 `DoneCheckmarkButton`；③ TextEditorView 键盘工具栏完成输入改用勾（行为仍 `editorFocused=false` 收起键盘、不 dismiss）。保持 chevron.down 的场景全是真「收起/关闭」：诊断面板、容器列表 more 关闭、文件调用态关闭、终端收起、排序箭头——不动。**⚠️ 图形语义铁律：✓ 勾=完成/确认/选中；⌄ 向下箭头=收起/折叠面板；✕=取消/丢弃。同类操作全 App 必须同款图形。 |
| **t1.90.2** | **图形语义三件套补全：取消用叉（CancelXButton）。** 用户补齐规范：✓ 完成 / ⌄ 关面板 / ✕ 取消，用图形替代文字以减少翻译文本。用户拍板范围=仅工具栏取消（alert 标准取消保留文字）。① TabModule 新增 `CancelXButton`（xmark / size 15 bold / .primary / 32×32，accessibility "Cancel"），与 `DoneCheckmarkButton`/`DismissChevronButton` 组成三件套；② 全 App 20 处 sheet/表单 `.topBarLeading`/`.cancellationAction` 的 `Button(L10n.t("Cancel")){dismiss()}` 批量替换为 `CancelXButton()`（容器创建、镜像拉取/打标签/导出/导入、编排模板、网络/卷创建、数据库 6 处、文件选择/压缩、文本编辑、目录选择、服务器表单）；③ 21 处 alert 的 `role: .cancel` 标准取消按钮保留文字不动（iOS HIG）。至此图形语义三件套覆盖完整，同类操作全 App 同款图形，且少大量 `L10n.t("Cancel")` 文案。 |

---

## 9. 踩坑清单（别重复踩）

| 现象 | 根因 / 正解 |
|---|---|
| 编译报错 `CodingKeys` 无 `inlinePassword` | 新增内存态字段要加入 `init(from:)` 手动赋值，但故意不进 CodingKeys（不落盘） |
| `.navigationDestination(item:)` 编译报错 requires Hashable（t1.87.0） | 该修饰符的 item 类型要求 `Hashable`（不只是 `Identifiable`）——签名是 `where D: Hashable`。给模型（如 ComposeDraft）声明 `Identifiable, Hashable` 即可（字段均可哈希时编译器自动合成）。fresh tag 重发。 |
| `docker compose ls --format json` 解析后列表恒定为空（t1.88.0） | 该命令输出**单个 JSON 数组** `[{...}]`，不是逐行 JSON。用 `decodeLines`（按 `\n` 切行、只认 `{` 开头）会因数组以 `[` 开头而全跳过。改为截取首尾 `[...]` 用 `[Model].self` 整体解析；兜底 JSON Lines。`docker ps --format '{{json .}}'` 才是逐行 JSON——两者别混用。另：`compose ls` 默认只列 running，要看全量须加 `--all`。 |
| compose ps 的 running 被显示为灰色停止（t1.89.0） | `DockerContainerState.from()` 按 `docker ps` 文本判断（`hasPrefix("up")` → running），但 `docker compose ps --format json` 的 State 是 `running`/`exited`/`paused`，"running" 不匹配 "up" → 误判 stopped。compose 服务状态须单独映射（`contains("running")`），勿套用 docker ps 的解析器。 |
| `private struct InfoRow` 跨文件引用编译失败（t1.89.0） | 详情页的 `InfoRow` 原来是 `private`，跨文件（ComposeProjectDetailView 在 ComposeListView.swift）引用会编译失败——Swift `private` 限定同文件。要跨文件复用就去掉 `private` 升为 internal（确认无同名冲突）。 |
| 编排页点「停止」后容器彻底消失（t1.90.0） | `docker compose down` = **停止并删除容器**（连同 compose 网络），不是 `docker stop`。用户以为只是停止，实际容器被删。正解：**编排页不暴露 down/stop/restart/删除项目**，容器启停统一在容器分区（`docker start/stop` 不删容器）。编排模块定位为只读查看：项目概览 + 服务列表（跳容器详情）+ yml。 |
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
| git push TLS/认证失败 | 用 GitHub Git Database API（见 8.2）；**若报 `GnuTLS recv error (-110): The TLS connection was non-properly terminated`（commit 已推、tag 推送反复中断），正解：本地 `git config http.version HTTP/1.1` + `http.lowSpeedLimit 1000` + `http.lowSpeedTime 20` + `http.postBuffer 524288000`，实测一次即通**（t1.85.0）。推送后务必用 API 校验远程 HEAD/ref 是否真的更新，别信 push 命令的退出码 |
| 下载 IPA 超时 / RemoteDisconnected | 用 asset API（`/repos/{o}/{r}/releases/assets/{id}`）+ `Accept: application/octet-stream` + 分块读取 + urllib 重试 |
| **t1.67 闪退（编译过但运行崩）** | `String(format:)` 用 `%@` 传 Swift `String` 会 EXC_BAD_ACCESS（须 NSString）。本地化带参文案改用 `L10n.f` 的**纯 `replacingOccurrences` 替换**（`%@` 顺序 / `%1$@` 指定位置），彻底不用 `String(format:)`。**以后任何带参本地化都别用 String(format:)**。 |
| 选完目录返回后上层表单 sheet 被收起 | 调用方本身是 sheet 时，别用根视图的全局 `fileOpenTarget` 弹 sheet（祖先弹 sheet 会收起后代 sheet）；改用 `directoryPickTarget` + 本地 `.folderPicker(item:)` 形成正确嵌套 |
| **切换中文就闪退** | `.id(localization.revision)` 挂在 body 根链上（该链还挂着设置/终端/调用态三个 `.sheet`）。换语言 revision+1 → 整条根链换身份 → 正在显示的 sheet 宿主被销毁重建 → 重新 present 崩溃。**正解：引入稳定 ZStack 根容器承载全部 sheet，`.id(revision)` 只挂在它的子视图 `contentArea` 上**——注意计算属性会内联，仅把 .id 移进 `contentArea` 而不加稳定根容器是**无效**的（展开后结构不变）；且 `revision` 自增用 `DispatchQueue.main.async` 推到下一 runloop，绝不在 Picker/Toggle 的 set（视图更新事务）内同步改身份。 |
| **切换中文闪退（t1.70 的 ZStack 方案仍没解决）** | 任何「运行期改生效语言 + 重建视图树」的方案都可能因 sheet 重新 present 崩溃。**最终正解：语言切换改为「重启后生效」**——`currentID`（生效）仅启动时从持久化读入、运行期恒定；Picker 绑定 `selectedID`（待选），`select()` 只改 selectedID + 持久化、绝不碰 currentID；彻底删除 `revision` 与 `.id(localization.revision)`。切换时不重算任何 L10n.t()、不重建任何视图，崩溃从根上消失。 |

| **切中文必崩（t1.71「重启生效」仍没解决，真正根因）** | 崩溃日志 `EXC_BREAKPOINT`/`SIGTRAP`/`brk 1` + 堆栈 `dispatch_once_callout` 表明是 Swift `static let` 懒初始化时 `preconditionFailure`，不是视图重建/野指针。`BuiltinPacks.zhHans` 是 561 条字典字面量且含 15 个重复 key；Swift 在 Release(-O) 下把字典字面量编译为 `Dictionary(uniqueKeysWithValues:)`，遇重复 key 直接 trap（Debug 逐条覆盖不崩，故本地复现不了、英文永不碰该字典故不崩）。**正解：①删除全部重复 key；②把字典字面量改成运行期 `var d=[:]; d[k]=v; return d` 闭包构建，编译器无法再用 uniqueKeysWithValues，重复也只覆盖不崩。** |
| **底部 Tab 标题切语言不生效** | 各 `*Tab.module` 是 `static let`，`title: L10n.t("X")` 在首次访问时求值即固化，视图重建也不重算。**正解：title 存英文 key（`title: "X"`），所有展示点（`ContentView.tabView` / `SettingsView.toggleableModules`）用 `L10n.t(module.title)`。** |
| **翻译模板导出点了没反应** | `UIActivityViewController` 当 SwiftUI `.sheet` 的 root 呈现，分享面板本身是 modal，套一层 sheet 时机不可靠。**正解：不用 sheet，找 keyWindow 顶层 VC（`presentedViewController` 链走到顶）直接 `present(activity:)`。** |
| **终端编辑菜单（复制/粘贴）不随 App 语言切换** | SwiftTerm 1.2.1 用 `UIMenuController`，标准项标题由系统按 `developmentRegion`(=en) 本地化，运行期改 L10n 表不影响。**⚠️ 错误方案（t1.75，导致 t1.76 致命回归）：method swizzling 全局替换 SwiftTerm 的 `canPerformAction`（public 非 open，子类不能 override）屏蔽标准 selector + willShowMenu 塞自定义 UIMenuItem——结果 copy/paste/selectAll 返回 false 被屏蔽、自定义项又没挂上，菜单全空，复制粘贴彻底没了。⚠️ 另一个坑：查 main 分支源码会误判——1.2.1 没有 `hasActiveSelection`、init 签名不同，照 main 写必编译失败。** ⚠️ 第二个坑（t1.76）：改 override `editMenu` 属性，编译报 `property does not override any property from its superclass`——SwiftTerm 1.2.1 的 TerminalView 继承链里没有可 override 的 editMenu。**最终结论（t1.76）：这条路在 SwiftTerm 上走不通。系统标准编辑菜单标题跟随 developmentRegion 是 iOS 系统级限制，App 内运行期切 L10n 表改不了，且 swift 层无法可靠覆盖（canPerformAction 非 open 不能 override、swizzle 会破坏功能、editMenu 父类不存在）。功能优先——保持 SwiftTerm 原生菜单（英文但复制粘贴完整），不要为菜单本地化冒险。** |
| **容器运行时长后面多一个 s** | 单位替换把译文当搜索 key：中文模式下 `L10n.t("months")`="个月"，拿"个月"找"months"找不到，再用单数 "month"→"个月" 把 "months" 拆成"个月s"。**正解：搜索 key 用硬编码英文单词、复数在前，译文只放 value。** |
| **压缩失败 tar: xxx: Cannot stat** | `tar -czf <产物> -C <父目录> <源项basename...>`：源项 basename 是相对「当前目录」的，却 `-C` 到父目录，tar 在父目录找不到源项。**正解：`-C` 必须切到当前目录（源项所在目录），产物用绝对路径；明确列 basename 而非 "."，避免把生成中的归档自身打进去。** |
---

## 10. 接手指南：常见任务怎么干

1. **改/加数据库能力**：改 `Database/Core/DatabaseService.swift` 命令构造 + `DatabaseView.swift` UI；四种类型都要分支适配；密码走环境变量；新增文件记得改 pbxproj；**必须走 CI 验证**；用新 tag 发版。
2. **新增一个可插拔模块**：建 `<Name>/<Name>Tab.swift`（导出 `TabModule`）+ View；在 `TabRegistry.modules` 加一行；如需开关，`ModuleID` 加 case（`isCore=false`）；如需设置项，填 `settingsSection`。删模块反过来即可。
3. **加悬浮终端的宿主模块**：在模块 TabModule 里设 `showsFloatingTerminal: true`。
4. **改终端行为**：动 `TerminalSession` / `TerminalView` 前，先读 6.1 与踩坑表；终端是底座，任何"模块级终端开关"都不能加。
5. **发版**：本地改完 → API 推送 → 新 `t*` tag → 等 CI → asset API 下载 → zip 校验 → `present_files` 交付。**版本号按 t1.N+1.0 递增**（当前基线 t1.96.0）。

### 当前待办 / 方向（供参考）

- 网站模块仍是空壳，是下一个大模块候选（PHP / Node / 反向代理 / 证书 / Nginx 编辑器）。
- 数据库需继续真机验证各镜像的账号 host / 权限模型差异，按反馈适配。
- 持续按"闭环、自助"标准审查每个功能：建库能否直接用新账号连接、改密后能否当次会话无缝继续、删除是否级联清理等。

---

### t1.95.0 上架 App Store 标准：全 App 交互审计修复 + 翻译模板体检

- **背景**：用户要求以"上架 App Store"标准逐按钮检查全 App（逻辑自洽 / 表述正确 / 位置合理），并"全修"，外加翻译模板体检。分 5 模块并行审计 + 主 Agent 亲自复核关键争议点（排除 2 处误报），共修 18 项。
- **高危（数据不可逆）**：① `QueryView` 执行任意 SQL/命令前按关键词判定破坏性语句（DROP/DELETE/TRUNCATE/FLUSHDB 等），命中弹不可撤销确认——此前完全无确认；② 数据库"重命名"实为建新库+迁移表+DROP 旧库（MySQL/MongoDB），文案改「迁移并替换数据库」+ 风险警告 + 二次确认（PostgreSQL 原子 ALTER 保持原名）。
- **中危**：容器详情页「从该容器创建编排模板」正名为「以此容器新建编排项目」（它实为克隆成新项目并部署、不进模板库），且只对非编排容器显示、加端口冲突脚注；卡片主操作失败不再吞掉（统一错误 alert）；网络创建 Driver 去掉 `host`/`none`（Docker 预定义网络不可 create）；连接删除/仓库退出登录加二次确认（如实告知删 Keychain 密码）；Redis 索引文案改为如实描述（清空走 FLUSHDB）；新增服务器强制校验凭证（否则存下连不上的服务器）；文件排序菜单文案统一为"点击后动作"；调用态"设为默认目录"按实际能力文案区分；跳层级不再清剪贴板（与系统返回一致）；预览失败提示本地化。
- **低危**：Stop 图标统一 `stop.fill`（原 pause.fill）；Registry 关闭浮层由 ✕ 改 ⌄；诊断空态 "tab"→"分区"；FAB 无障碍文案 "long press"→"drag"；**终端工具栏（字号 Aa/重连/收起/齿轮）经评估保留**——均为高频核心操作、注释详实、收进 ⋯ 反降效，符合"工具类 App 打开即干活"。
- **语言机制文档纠偏**：t1.71 历史条目（重启后生效）不动——它是真实版本演进；但架构节错误描述"`revision` 驱动根 `.id()` 重建"已改为当前实际机制（即时生效、`scheduleBump` 仅轻量信号、不用 `.id()` 重建）。语言包导入同 id 弹覆盖确认、删除当前生效包告知回退英文。
- **翻译模板体检**：精确扫描全库 779 个 L10n key（还原 Swift `\"` 转义后比对），补齐 27 个缺失译文（含 3 个历史遗留 + 24 个本轮新增），BuiltinPacks 与 xcstrings 双写；重复 key 仅历史 `OK`（无碍）。**导出模板取 `BuiltinPacks.zhHans.keys` 全量，新 key 自动纳入。**
- **一条铁律**：危险操作（SQL 执行、迁移型重命名、删连接/凭证、覆盖率）必须二次确认且如实告知后果；失败不能静默吞掉；"模板"一词专属模板库，从容器生成的是"编排项目"不是模板。

### t1.96.0 从容器创建模板统一到编排模板页
- **入口收敛**：容器详情页移除「以此容器新建编排项目」（连同 `composeDraft`/`prepareCompose`/`navigationDestination`），避免与「重建容器」两个菜单并列困扰。底层 `generateComposeDraft` 能力保留（关入口不关能力）。
- **新入口**：Docker 右上 ⋯ →「编排模板」页新增「从已有容器创建模板」→ 容器选择页（**只列非编排容器**：`!isComposeManaged`）→ 选中反向生成草稿 → 保存页（可改模板名/编辑 yml/看 warnings）→ 存入 `ComposeTemplateStore`「我的模板」。
- **边界铁律补充**：编排容器已有 yml，存模板走编排详情页 `docker compose config` 快照（质量高、变量已展开）；非编排容器没有 yml，反向生成是唯一途径。两条路径互斥，不在同一列表里重复列编排容器。`ComposeTemplateStore.save` 增加可选 `detail`/`symbol` 参数以标注来源。

*最后更新：2026-11-28，基线 t1.96.0。文档随版本演进同步更新。*

### t1.94.0 保存为模板改为「快照」：展开变量成实值

- **背景/拍板**：用户发现 t1.93 存的模板里 `${VAR}` 还是变量占位符，直接从模板部署会因缺 `.env` 把变量解析成空串，还原不了原容器。用户拍板方案 A——**把模板存成快照**：保存时展开变量成当前实值，从模板部署即一键还原；用户想改就在编辑器里改那个 yml（改实值或自己写回变量都行）。
- **关键点：真相来源是 `.env`**。`docker compose config` 会从 compose 文件所在目录读 `.env`、展开 `${VAR}`、输出规范化 yml。快照正是这个输出，自带实值、不依赖 `.env`。
- **实现**：
  - `DockerService.renderComposeConfig(path:project:)`：`docker compose -f <path> -p <name> config`，取 stdout（空输出视为失败）；新增本地化 key「Failed to render compose config」。
  - 详情页 Save as template 按钮改为异步 `saveTemplate()`：先展开 → 成功存快照 + 提示"变量已展开，部署可还原"；失败降级存原始 yml + 如实提示"已保存原始配置"（不丢内容）。
  - 提示文案随结果动态（`saveNote`），替换原来写死的成功文案。
- **本地化**：新增 4 key 双补（Failed to render compose config / 展开提示 / 快照成功提示 / 降级提示）；重复 key 检查通过（仅历史 `OK`）。

### t1.93.0 编辑浮层关闭箭头 + 保存为编排模板

- **编辑浮层右上角关闭箭头**：`ComposeProjectDetailView` 里 sheet 承载的 `ComposeEditorView` 之前没被 NavigationStack 包裹，navigationTitle 与 toolbar 都不显示（截图里只看到 Form 的 section header，右上角空白）。**正解：sheet 内用 `NavigationStack` 包一层 + 右上角 `DismissChevronButton`（chevron.down）**。`ComposeEditorView` 在 push 场景由外层提供 NavigationStack，此改动只动 sheet 调用处，不影响模板/容器转编排两条 push 流程。
- **保存为编排模板（用户拍板：按钮放编排详情页，模板并入现有编排模板列表）**：
  - `ComposeTemplate` 加 `Codable` + `isCustom` 字段 + 自定义 init（内置模板 isCustom=false）。
  - 新建 `ComposeTemplateStore`（放 `ComposeTemplateView.swift` 同文件，免改 pbxproj）：`@Published customTemplates`，UserDefaults 持久化，同名覆盖（先删后插），保存/删除/加载。**模板是配置文本跟 App 本地走，不跟服务器走。**
  - 编排详情页 yml Section 加「保存为模板」（`doc.badge.plus`），弹 alert 命名（预填项目名），存当前 yml；保存成功 alert 确认。
  - `ComposeTemplateView` 加「我的模板」Section：点条目 push `ComposeEditorView` 编辑部署（复用现有导航），垃圾桶按钮删除。内置模板分区不变。
- **本地化**：新增 9 key（Untitled template / Saved from a compose project / My templates / Save as template / Template name / Saved / 三条长句），BuiltinPacks + xcstrings 双补；重复 key 检查通过（仅历史 `OK`）。

### t1.92.0 重建入口按容器来源分流：可视化表单复活（只对非编排容器）

- **背景**：t1.91 去掉了容器详情「编辑容器」入口，导致那套可视化表单（`ContainerCreateView` 编辑模式 / `from(inspect:)` / `recreateContainer`）变成死代码。用户拍板精细化分流——**不是砍掉能力，而是按容器来源决定要不要暴露**。
- **判定依据**：`DockerContainer.isComposeManaged` —— 解析 `docker ps --format '{{json .}}'` 的 `Labels`（逗号分隔 `k=v`），含 `com.docker.compose.project=` 即为编排容器（compose up 自动打此标签）。
- **分流规则**：
  - 编排容器 → 详情页**不显示**重建入口（改配置去编排页改 yml 再 up；在此重建会脱编排且下次 up 被覆盖）。
  - 非编排容器（docker run 等）→ 详情页入口区显示「重建容器」按钮（`Recreate container`），复用 `prepareEdit` → `ContainerCreateSpec.from(inspect:)` 预填 → `ContainerCreateView` 编辑模式 sheet → `recreateContainer`（停→改名备份→docker run 同名→成功删备份/失败回滚）。重建出来仍是非编排容器，不影响任何 compose 项目。
- **关键认知**：可视化编辑（docker run 重建）**不会**把普通容器变成编排容器——不带 compose 标签；反过来编排容器经它重建反而**脱离**编排。真正转成编排的唯一路径是「从该容器创建编排模板」→ 生成 yml → `compose up -d` 打标签。
- **能力未删**：t1.91 保留的底层能力此轮重新接回入口，死代码问题消解。编排页就地编辑 yml 的逻辑不变。

### t1.91.0 编排编辑收敛：编辑入口只留在编排，去掉容器"原地重建"

- **理念确认 / 边界铁律**：**编排只管编排创建的容器**——真相来源是 yml。非编排创建的容器（docker run 等）做"重建式原地编辑"不理想（重建会脱离编排，下次 `up` 又会被 yml 覆盖），**一律不在容器详情页提供原地编辑**。这类容器若真想纳入编排，唯一路径是容器详情页已有的「从该容器创建编排模板」（`prepareCompose`）生成 yml 草稿再部署——**此入口刻意保留，勿删**。一句话记住：**改配置只改 yml；容器详情只做运行态操作（启停/日志/终端）+ 转编排，不做原地重建编辑。**
- **去掉容器"编辑容器"入口**：`ContainerDetailView` 删除编辑按钮 / `prepareEdit` / `editSpec` sheet / `ContainerEditDraft`。**底层能力按"关入口不关能力"全部保留**：`DockerService.recreateContainer`、`ContainerCreateView.EditContext` + 编辑 init、`ContainerCreateSpec.from(inspect:)` 均不动，将来需要可随时接回入口。
- **编排详情页就地编辑 yml**：`ComposeProjectDetailView` 的"Compose 文件内容"Section 加 `Edit compose file` 按钮，用 `.sheet` 承载 `ComposeEditorView(existingConfigPath:)`（sheet 模态覆盖，**不加深导航层级**——用户明确"不要太多层级"）。保存走 `updateComposeFile` 覆盖原文件 + `deployCompose`（`up -d`），**不广播 `composeDeployed`**（避免弹走详情页），`onDeployed` 里关 sheet + `load()` 刷新。
- **安全边界不变**：编排页仍不提供 down/stop/restart/delete 任何操作（down 会删容器，用户实测过）。`up -d` 即便 yml 移除 service 也不会删已有容器（无 `--remove-orphans`），安全。
