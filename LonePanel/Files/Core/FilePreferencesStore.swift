import Foundation

/// Files 模块私有：全局视图偏好持久化。
/// 按需求所有设置项「按全局记忆」，不按服务器区分。默认目录仍由 DefaultDirectoryStore 按服务器保存。
enum FilePreferencesStore {
    private static let defaults = UserDefaults.standard
    private enum Key {
        static let viewMode = "com.lone.lonepanel.files.prefs.viewmode"
        static let sortOrder = "com.lone.lonepanel.files.prefs.sortorder"
        static let sortAscending = "com.lone.lonepanel.files.prefs.sortascending"
        static let showHiddenFiles = "com.lone.lonepanel.files.prefs.showhidden"
    }

    static var viewMode: FileViewMode {
        get {
            guard let raw = defaults.string(forKey: Key.viewMode),
                  let value = FileViewMode(rawValue: raw) else { return .list }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: Key.viewMode) }
    }

    static var sortOrder: FileSortOrder {
        get {
            guard let raw = defaults.string(forKey: Key.sortOrder),
                  let value = FileSortOrder(rawValue: raw) else { return .name }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: Key.sortOrder) }
    }

    /// Bool 默认升序：键不存在时 bool(forKey:) 会返回 false，故用 object 判空区分。
    static var sortAscending: Bool {
        get {
            guard defaults.object(forKey: Key.sortAscending) != nil else { return true }
            return defaults.bool(forKey: Key.sortAscending)
        }
        set { defaults.set(newValue, forKey: Key.sortAscending) }
    }

    static var showHiddenFiles: Bool {
        get { defaults.bool(forKey: Key.showHiddenFiles) }
        set { defaults.set(newValue, forKey: Key.showHiddenFiles) }
    }
}
