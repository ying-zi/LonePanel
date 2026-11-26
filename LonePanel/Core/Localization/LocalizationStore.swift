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

    /// 当前选中的语言包 id（en / zh-Hans / 自定义 id）。持久化到 UserDefaults + KVS。
    @Published private(set) var currentID: String = "en"
    /// 已导入的自定义包（存本地 Documents；iCloud 可用时镜像到 iCloud Drive）。
    @Published private(set) var customPacks: [LanguagePack] = []
    /// iCloud 是否真正可用（运行时探测，未声明 entitlement 时为 false）。
    @Published private(set) var iCloudAvailable: Bool = false

    /// 视图树刷新信号：换语言后 let 常量里的文案也需要重算，靠它驱动 .id()。
    @Published private(set) var revision: Int = 0

    private let defaults = UserDefaults.standard
    private let kvs = NSUbiquitousKeyValueStore.default
    private let currentIDKey = "com.lone.lonepanel.locale.id"
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

    func select(_ id: String) {
        guard id == "en" || id == "zh-Hans" || customPacks.contains(where: { $0.id == id }) else { return }
        currentID = id
        defaults.set(id, forKey: currentIDKey)
        kvs.set(id, forKey: currentIDKey)   // 无 entitlement 时自动落本地，安全
        kvs.synchronize()
        bump()
    }

    private func bump() { revision &+= 1 }

    // MARK: - 导入 / 导出

    /// 从 JSON 数据导入语言包（校验 + 去重 + 覆盖同 id）。返回导入后的包。
    @discardableResult
    func importPack(data: Data) throws -> LanguagePack {
        let pack = try LanguagePack.decode(from: data)
        customPacks.removeAll { $0.id == pack.id }
        customPacks.append(pack)
        persistCustomPacks()
        if currentID == pack.id { bump() }
        return pack
    }

    func removePack(id: String) {
        customPacks.removeAll { $0.id == id }
        persistCustomPacks()
        // 删掉正在用的包则回退英文
        if currentID == id { select("en") }
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
        currentID = defaults.string(forKey: currentIDKey) ?? "en"
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
        if let synced = kvs.string(forKey: currentIDKey), synced != currentID {
            currentID = synced
            defaults.set(synced, forKey: currentIDKey)
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
        bump()
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
            // 同步其他设备改动的「当前语言」。
            if let synced = self.kvs.string(forKey: self.currentIDKey),
               synced != self.currentID,
               synced == "en" || synced == "zh-Hans" || self.customPacks.contains(where: { $0.id == synced }) {
                self.currentID = synced
                self.defaults.set(synced, forKey: self.currentIDKey)
                self.bump()
            }
        }
    }

    /// 把自定义包镜像到 iCloud Drive；无 entitlement 时静默跳过。
    private func mirrorPacksToICloud() {
        guard iCloudAvailable, let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return }
        let remote = container.appendingPathComponent(packsDirName, isDirectory: true)
        try? FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        for pack in customPacks {
            if let data = try? pack.encodedJSON() {
                try? data.write(to: remote.appendingPathComponent("\(pack.id).json"), options: .atomic)
            }
        }
    }
}
