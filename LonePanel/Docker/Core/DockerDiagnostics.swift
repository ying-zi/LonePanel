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
            command: command,
            exit: exit,
            out: String(out.prefix(400)),
            err: String(err.prefix(400))
        )
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    /// 拼成可复制的纯文本报告。
    var report: String {
        entries.map { e in
            "[\(e.time)] \(e.command)\\n  exit=\(e.exit)\\n  out=\(e.out.isEmpty ? "(empty)" : e.out)\\n  err=\(e.err.isEmpty ? "(empty)" : e.err)"
        }
        .joined(separator: "\n\n")
    }
}
