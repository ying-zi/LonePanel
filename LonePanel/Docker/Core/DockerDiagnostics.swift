import Foundation
import SwiftUI

/// Docker 命令诊断记录：保存最近若干条命令的退出码与原始输出，供 UI 排查。
/// 仅保存在内存，App 重启即清空；不落盘、不外传。
@MainActor
final class DockerDiagnostics: ObservableObject {
    static let shared = DockerDiagnostics()

    struct Entry: Identifiable {
        let id = UUID()
        let time: String
        let command: String
        let exit: Int
        let out: String
        let err: String
    }

    @Published private(set) var entries: [Entry] = []
    private let maxEntries = 30

    func record(command: String, exit: Int, out: String, err: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let entry = Entry(
            time: formatter.string(from: Date()),
            command: Self.redact(command),
            exit: exit,
            out: String(Self.redact(out).prefix(400)),
            err: String(Self.redact(err).prefix(400))
        )
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    /// 敏感信息打码：`docker login` 的密码无论出现在命令（`-p`/`--password`）
    /// 还是输出/错误里，一律替换为 ******，防止明文密码进入诊断面板或被复制外传。
    private static func redact(_ text: String) -> String {
        // --password 参数无条件打码（含输出/错误里可能的回显）。
        var result = redactPattern(
            text,
            pattern: "(--password[= ]+)(['\\\"]?)[^\\s'\\\"]+\\2",
            template: "$1$2******"
        )
        // -p 也是 docker run 的端口参数，只在 login 场景打码，避免误伤端口展示。
        if text.lowercased().contains("login") {
            result = redactPattern(
                result,
                pattern: "((?:^|\\s)-p\\s+)(['\\\"]?)[^\\s'\\\"]+\\2",
                template: "$1$2******"
            )
        }
        return result
    }

    /// 用正则把匹配片段按模板替换（$1/$2 为捕获组）。
    private static func redactPattern(_ text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    /// 拼成可复制的纯文本报告。
    var report: String {
        entries.map { e in
            "[\(e.time)] \(e.command)\\n  exit=\(e.exit)\\n  out=\(e.out.isEmpty ? "(empty)" : e.out)\\n  err=\(e.err.isEmpty ? "(empty)" : e.err)"
        }
        .joined(separator: "\n\n")
    }
}
