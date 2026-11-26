import Foundation
import Combine

/// 本地化引擎：管理当前语言包、查表、导入导出、iCloud（偏好 + 自定义包）同步。
///
/// - 源语言为英文：源码里的字符串字面量即 key（英文），内置英文包为 identity（查不到就返回 key 本身）。
/// - 内置中文包由 BuiltinPacks 提供；用户可导入自定义 JSON 包。
/// - iCloud：偏好（当前语言、界面开关）走 NSUbiquitousKeyValueStore；自定义包 JSON 走 iCloud Drive。
///   侧载 / 免费签没有 iCloud entitlement 时，两处都会自动降级为本地存储，绝不崩溃。
final class LocalizationStore: ObservableObject {
    static let shared = LocalizationStore()

    /// 当前**生效**的语言包 id（en / zh-Hans / 自定义 id）。仅在 App 启动时从持久化读入，
    /// 运行期恒定不变——所以切换语言不会触发任何 L10n.t() 重算，也就不需要重建视图树，
    /// 从根本上杜绝了切换语言时 .id 换身份导致正在显示的 sheet 被重新 present 的闪退。
    @Published private(set) var currentID: String = "en"
    /// 用户**本次选择、待重启生效**的语言 id。Picker 绑定的是它；切换只改它 + 持久化，
    /// 不碰 currentID。下次启动 loadLocal 才会把持久化值提升为 currentID。
    @Published private(set) var selectedID: String = "en"
    /// 已导入的自定义包（存本地 Documents；iCloud 可用时镜像到 iCloud Drive）。
    @Published private(set) var customPacks: [LanguagePack] = []
    /// iCloud 是否真正可用（运行时探测，未声明 entitlement 时为 false）。
    @Published private(set) var iCloudAvailable: Bool = false
    /// 用户是否开启 iCloud 同步（偏好走 KVS，开关本身也随 iCloud 同步）。
    @Published private(set) var iCloudSyncEnabled: Bool = true

    private let defaults = UserDefaults.standard
    private let kvs = NSUbiquitousKeyValueStore.default
    private let currentIDKey = "com.lone.lonepanel.locale.id"
    private let cloudSyncKey = "com.lone.lonepanel.locale.icloudsync"
    private let packsDirName = "LanguagePacks"

    private var cancellable: AnyCancellable?

    private init() {
        loadLocal()
        observeICloud()
        refreshICloudAvailability()
    }

    // MARK: - 查表

    /// 核心查表：英文原文 -> 当前语言译文；查不到回退英文原文。
    func t(_ english: String) -> String {
        if currentID == "en" { return english }
        if currentID == "zh-Hans" { return BuiltinPacks.zhHans[english] ?? english }
        if let pack = customPacks.first(where: { $0.id == currentID }) {
            return pack.strings[english] ?? english
        }
        return english
    }

    /// 当前包显示名（设置页 / 语言列表用）。
    var currentName: String {
        packName(for: currentID)
    }

    func packName(for id: String) -> String {
        switch id {
        case "en": return "English"
        case "zh-Hans": return "简体中文"
        default: return customPacks.first(where: { $0.id == id })?.name ?? id
        }
    }

    /// 当前语言是否把英文原文原样显示（英文包或未知包）。
    var isSourceLanguage: Bool { currentID == "en" }

    // MARK: - 切换

    /// 切换语言：只记录用户选择并持久化，**不修改运行期生效的 currentID**。
    /// 生效语言在下次启动时由 loadLocal 从持久化读入。这样切换时不重算任何文案、
    /// 不重建任何视图树，从根本上避免切换瞬间的闪退。
    func select(_ id: String) {
        guard id == "en" || id == "zh-Hans" || customPacks.contains(where: { $0.id == id }) else { return }
        selectedID = id
        defaults.set(id, forKey: currentIDKey)
        if iCloudSyncEnabled {
            kvs.set(id, forKey: currentIDKey)   // 无 entitlement 时自动落本地，安全
            kvs.synchronize()
        }
    }

    /// 本次选择是否已与生效语言不同（用于「重启后生效」提示）。
    var hasPendingLanguageChange: Bool { selectedID != currentID }

    /// 开启/关闭 iCloud 同步。关闭后不写 KVS、不镜像语言包；开启时立即镜像一次。
    func setiCloudSync(_ enabled: Bool) {
        iCloudSyncEnabled = enabled
        defaults.set(enabled, forKey: cloudSyncKey)
        kvs.set(enabled, forKey: cloudSyncKey)
        kvs.synchronize()
        if enabled { mirrorPacksToICloud() }
    }

    // MARK: - 导入 / 导出

    /// 从 JSON 数据导入语言包（校验 + 去重 + 覆盖同 id）。返回导入后的包。
    @discardableResult
    func importPack(data: Data) throws -> LanguagePack {
        let pack = try LanguagePack.decode(from: data)
        customPacks.removeAll { $0.id == pack.id }
        customPacks.append(pack)
        persistCustomPacks()
        return pack
    }

    func removePack(id: String) {
        customPacks.removeAll { $0.id == id }
        persistCustomPacks()
        // 删掉待选的包则回退英文（运行期生效语言恒定，重启后再统一应用）
        if selectedID == id { select("en") }
    }

    /// 导出指定包为 JSON（内置包也可导出，作为翻译模板）。
    func exportData(for id: String) -> Data? {
        if id == "en" {
            // 英文包导出为「英文 -> 英文」的翻译模板，供用户填写译文。
            let allKeys = Set(BuiltinPacks.zhHans.keys)
            let template = Dictionary(uniqueKeysWithValues: allKeys.map { ($0, $0) })
            let pack = LanguagePack(id: "template-en", name: "Translation Template (from English)",
                                    version: "1.0", strings: template)
            return try? pack.encodedJSON()
        }
        if id == "zh-Hans" {
            let pack = LanguagePack(id: "zh-Hans-copy", name: "简体中文（导出）",
                                    version: "1.0", strings: BuiltinPacks.zhHans)
            return try? pack.encodedJSON()
        }
        guard let pack = customPacks.first(where: { $0.id == id }) else { return nil }
        return try? pack.encodedJSON()
    }

    /// 内置 + 自定义的全部可选语言。
    var availablePacks: [(id: String, name: String)] {
        var list = [(id: "en", name: "English"), (id: "zh-Hans", name: "简体中文")]
        list += customPacks.map { (id: $0.id, name: $0.name) }
        return list
    }

    // MARK: - 本地持久化

    private func loadLocal() {
        let saved = defaults.string(forKey: currentIDKey) ?? "en"
        // 启动时持久化值即为本次「生效语言」；selectedID 初值与之一致。
        currentID = saved
        selectedID = saved
        let dir = packsDirectory()
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            var loaded: [LanguagePack] = []
            for url in files where url.pathExtension == "json" {
                if let data = try? Data(contentsOf: url),
                   let pack = try? LanguagePack.decode(from: data) {
                    loaded.append(pack)
                }
            }
            customPacks = loaded.sorted { $0.name < $1.name }
        }
        // KVS 里若有更新的当前语言（例如 iCloud 另一台设备选的），以 KVS 为准。
        // 同样是启动阶段，直接提升为生效语言。
        if let synced = kvs.string(forKey: currentIDKey), synced != currentID {
            currentID = synced
            selectedID = synced
            defaults.set(synced, forKey: currentIDKey)
        }
        // iCloud 同步开关：KVS 优先（另一台设备的选择），否则本地，默认开。
        if let synced = kvs.object(forKey: cloudSyncKey) as? Bool {
            iCloudSyncEnabled = synced
        } else if let local = defaults.object(forKey: cloudSyncKey) as? Bool {
            iCloudSyncEnabled = local
        }
    }

    private func persistCustomPacks() {
        let dir = packsDirectory()
        for pack in customPacks {
            if let data = try? pack.encodedJSON() {
                try? data.write(to: url(forPackID: pack.id), options: .atomic)
            }
        }
        mirrorPacksToICloud()
    }

    private func packsDirectory() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(packsDirName, isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func url(forPackID id: String) -> URL {
        packsDirectory().appendingPathComponent("\(id).json")
    }

    // MARK: - iCloud（优雅降级）

    private func refreshICloudAvailability() {
        // ubiquityIdentityToken 为 nil 表示未登录 iCloud 或未开启 capability。
        iCloudAvailable = FileManager.default.ubiquityIdentityToken != nil
    }

    private func observeICloud() {
        cancellable = NotificationCenter.default.publisher(
            for: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvs
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] note in
            guard let self else { return }
            self.refreshICloudAvailability()
            // 同步其他设备改动的开关本身。
            if let synced = self.kvs.object(forKey: self.cloudSyncKey) as? Bool, synced != self.iCloudSyncEnabled {
                self.iCloudSyncEnabled = synced
                self.defaults.set(synced, forKey: self.cloudSyncKey)
            }
            guard self.iCloudSyncEnabled else { return }
            // 同步其他设备改动的「当前语言」：只更新待选 selectedID 并持久化，
            // 不动运行期生效的 currentID——外部通知同样属于视图更新之外的异步时机，
            // 但为保持「重启生效」的一致语义，一律等下次启动统一应用。
            if let synced = self.kvs.string(forKey: self.currentIDKey),
               synced != self.selectedID,
               synced == "en" || synced == "zh-Hans" || self.customPacks.contains(where: { $0.id == synced }) {
                self.selectedID = synced
                self.defaults.set(synced, forKey: self.currentIDKey)
            }
        }
    }

    /// 把自定义包镜像到 iCloud Drive；无 entitlement 时静默跳过。
    private func mirrorPacksToICloud() {
        guard iCloudSyncEnabled, iCloudAvailable, let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return }
        let remote = container.appendingPathComponent(packsDirName, isDirectory: true)
        try? FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        for pack in customPacks {
            if let data = try? pack.encodedJSON() {
                try? data.write(to: remote.appendingPathComponent("\(pack.id).json"), options: .atomic)
            }
        }
    }
}
