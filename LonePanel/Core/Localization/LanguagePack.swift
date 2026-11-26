import Foundation

/// 一份语言包。strings 的 key 统一为**英文原文**（源语言），value 为译文。
/// 内置英文包 identity（key 即 value）、内置中文包见 BuiltinPacks；
/// 用户导入的自定义包沿用同一结构，因此可与内置包自由互换、导出备份。
struct LanguagePack: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let version: String
    let strings: [String: String]

    var isBuiltin: Bool { id == "en" || id == "zh-Hans" }

    /// Telegram 式导入文件的顶层结构。
    static func decode(from data: Data) throws -> LanguagePack {
        let decoder = JSONDecoder()
        let pack = try decoder.decode(LanguagePack.self, from: data)
        guard !pack.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LanguagePackError.invalid("语言包缺少 id")
        }
        guard !pack.strings.isEmpty else {
            throw LanguagePackError.invalid("语言包没有任何翻译条目")
        }
        // 自定义包不能用内置保留 id，避免覆盖内置包。
        guard pack.id != "en" && pack.id != "zh-Hans" else {
            throw LanguagePackError.invalid("自定义语言包不能使用保留 id（en / zh-Hans）")
        }
        return pack
    }

    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

enum LanguagePackError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return "Invalid language pack: \(reason)"
        }
    }
}
