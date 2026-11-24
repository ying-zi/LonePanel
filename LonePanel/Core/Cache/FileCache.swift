import Foundation
import CryptoKit

/// 通用磁盘缓存（所有模块共用）。特性：
/// - 存储于 Caches 目录（可重建、不进 iCloud 备份）；
/// - 按 category 分区，支持按类别统计与清理；
/// - 1 GB 容量上限，超出后按「最近最少使用」淘汰到 80% 水位；
/// - 索引落盘，App 重启后占用统计与命中继续有效；
/// - 线程安全：所有读写经串行队列，命中会刷新访问时间。
///
/// key 由调用方构造，建议含足够的去重维度（如 服务器ID|路径|大小|修改时间），
/// 缓存层本身不解释 key 语义，只做稳定哈希后作为文件名。
final class FileCache {
    static let shared = FileCache()

    /// 缓存上限 1 GB；超出后淘汰到 80%（800 MB），避免每次写入都连续删除。
    let capacityLimit: Int64 = 1024 * 1024 * 1024
    private let targetRatio = 0.8

    private let root: URL
    private let indexURL: URL
    private let queue = DispatchQueue(label: "com.lone.lonepanel.filecache", qos: .utility)
    private var entries: [String: CacheEntry] = [:] // key -> 条目
    private var loaded = false

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        root = caches.appendingPathComponent("LonePanelCache", isDirectory: true)
        indexURL = root.appendingPathComponent("index.json")
        queue.sync { loadIndexLocked() }
    }

    // MARK: - 对外 API（均 async，内部切到串行队列）

    /// 命中则返回缓存文件 URL（本地路径，可直接交 QuickLook / 分享），并刷新访问时间；未命中返回 nil。
    func url(forKey key: String) async -> URL? {
        await withCheckedContinuation { cont in
            queue.async {
                self.ensureLoadedLocked()
                guard let entry = self.entries[key] else { return cont.resume(returning: nil) }
                let url = self.fileURL(for: entry)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    // 文件被系统清掉了，移除失效索引项
                    self.entries.removeValue(forKey: key)
                    self.saveIndexLocked()
                    return cont.resume(returning: nil)
                }
                self.touchLocked(entry, key: key)
                cont.resume(returning: url)
            }
        }
    }

    /// 命中则返回数据；未命中返回 nil。
    func data(forKey key: String) async -> Data? {
        guard let url = await url(forKey: key) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// 写入缓存并在必要时触发 LRU 淘汰；返回落盘后的文件 URL。
    /// - fileName: 保留扩展名，系统靠它识别预览/分享类型。
    @discardableResult
    func store(_ data: Data, forKey key: String, category: String, fileName: String) async -> URL? {
        await withCheckedContinuation { cont in
            queue.async {
                self.ensureLoadedLocked()
                let entry = CacheEntry(
                    key: key,
                    category: category,
                    fileName: self.hashedFileName(key: key, original: fileName),
                    size: Int64(data.count),
                    lastAccess: Date()
                )
                let url = self.fileURL(for: entry)
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                    // 覆盖写：先扣除旧条目占用
                    if let old = self.entries[key] {
                        try? FileManager.default.removeItem(at: self.fileURL(for: old))
                    }
                    self.entries[key] = entry
                    self.evictIfNeededLocked()
                    self.saveIndexLocked()
                    cont.resume(returning: url)
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// 当前缓存总占用（字节）。
    func totalSize() async -> Int64 {
        await withCheckedContinuation { cont in
            queue.async {
                self.ensureLoadedLocked()
                cont.resume(returning: self.entries.values.reduce(Int64(0)) { $0 + $1.size })
            }
        }
    }

    /// 按类别聚合占用与条目数。
    func categoryUsage() async -> [CacheCategoryUsage] {
        await withCheckedContinuation { cont in
            queue.async {
                self.ensureLoadedLocked()
                var map: [String: (size: Int64, count: Int)] = [:]
                for e in self.entries.values {
                    let cur = map[e.category] ?? (0, 0)
                    map[e.category] = (cur.size + e.size, cur.count + 1)
                }
                let list = map.map { CacheCategoryUsage(category: $0.key, size: $0.value.size,
                                                        count: $0.value.count) }
                    .sorted { $0.size > $1.size }
                cont.resume(returning: list)
            }
        }
    }

    /// 清空全部缓存。
    func clearAll() async {
        await withCheckedContinuation { cont in
            queue.async {
                self.ensureLoadedLocked()
                for entry in self.entries.values {
                    try? FileManager.default.removeItem(at: self.fileURL(for: entry))
                }
                self.entries.removeAll()
                self.saveIndexLocked()
                cont.resume()
            }
        }
    }

    /// 按类别清理。
    func clear(category: String) async {
        await withCheckedContinuation { cont in
            queue.async {
                self.ensureLoadedLocked()
                let victims = self.entries.values.filter { $0.category == category }
                for entry in victims {
                    try? FileManager.default.removeItem(at: self.fileURL(for: entry))
                    self.entries.removeValue(forKey: entry.key)
                }
                self.saveIndexLocked()
                cont.resume()
            }
        }
    }

    // MARK: - 内部实现（均在 queue 上调用）

    private struct CacheEntry: Codable {
        let key: String
        let category: String
        let fileName: String
        let size: Int64
        var lastAccess: Date
    }

    private func ensureLoadedLocked() {
        if !loaded { loadIndexLocked() }
    }

    private func loadIndexLocked() {
        loaded = true
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([CacheEntry].self, from: data) else { return }
        for entry in list { entries[entry.key] = entry }
    }

    private func saveIndexLocked() {
        let list = Array(entries.values)
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: indexURL, options: .atomic)
    }

    private func touchLocked(_ entry: CacheEntry, key: String) {
        var updated = entry
        updated.lastAccess = Date()
        entries[key] = updated
        saveIndexLocked()
    }

    private func evictIfNeededLocked() {
        let total = entries.values.reduce(Int64(0)) { $0 + $1.size }
        guard total > capacityLimit else { return }
        let target = Int64(Double(capacityLimit) * targetRatio)
        var current = total
        // 最久未访问优先淘汰
        let ordered = entries.values.sorted { $0.lastAccess < $1.lastAccess }
        for entry in ordered {
            guard current > target else { break }
            try? FileManager.default.removeItem(at: fileURL(for: entry))
            entries.removeValue(forKey: entry.key)
            current -= entry.size
        }
    }

    private func fileURL(for entry: CacheEntry) -> URL {
        root.appendingPathComponent(safeFolder(entry.category), isDirectory: true)
            .appendingPathComponent(entry.fileName)
    }

    /// 用 SHA256 把任意 key 变成稳定、合法的文件名，保留原扩展名供系统识别类型。
    private func hashedFileName(key: String, original: String) -> String {
        let hash = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let ext = (original as NSString).pathExtension
        return ext.isEmpty ? hash : "\(hash).\(ext)"
    }

    private func safeFolder(_ category: String) -> String {
        let allowed = category.unicodeScalars.filter { $0.value > 31 && $0.value != 47 && $0.value != 92 }
        let cleaned = String(String.UnicodeScalarView(allowed))
        return cleaned.isEmpty ? "misc" : cleaned
    }
}

/// 单个类别的缓存占用（设置页展示用）。
struct CacheCategoryUsage: Identifiable {
    let category: String
    let size: Int64
    let count: Int
    var id: String { category }
}
