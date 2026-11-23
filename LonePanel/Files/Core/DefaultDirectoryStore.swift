import Foundation

/// Files 模块私有：按服务器保存「默认访问目录」。
/// 只存路径字符串，与服务器业务配置解耦；Key 前缀避免与其他模块冲突。
enum DefaultDirectoryStore {
    private static let prefix = "com.lone.lonepanel.files.defaultdir."

    static func path(for serverID: UUID) -> String? {
        UserDefaults.standard.string(forKey: prefix + serverID.uuidString)
    }

    static func set(_ path: String, for serverID: UUID) {
        UserDefaults.standard.set(path, forKey: prefix + serverID.uuidString)
    }

    static func clear(for serverID: UUID) {
        UserDefaults.standard.removeObject(forKey: prefix + serverID.uuidString)
    }
}
