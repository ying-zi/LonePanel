import SwiftUI

/// 容器日志页：进入即拉取尾部日志，可自动刷新、搜索关键词、复制全部。
struct ContainerLogsView: View {
    let containerID: String
    let containerName: String

    /// 日志时间范围，对应 1Panel 的 10 分钟 / 1 小时 / 1 天 / 全部。
    enum LogRange: String, CaseIterable, Identifiable {
        case tail300 = "最近 300 行"
        case minutes10 = "最近 10 分钟"
        case hour1 = "最近 1 小时"
        case day1 = "最近 1 天"

        var id: String { rawValue }
        var sinceArg: String? {
            switch self {
            case .tail300: return nil
            case .minutes10: return "10m"
            case .hour1: return "1h"
            case .day1: return "24h"
            }
        }
    }

    @State private var logs = ""
    @State private var isLoading = false
    @State private var autoRefresh = true
    @State private var keyword = ""
    @State private var copied = false
    @State private var range: LogRange = .tail300
    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var refreshTimer = TimerHolder()
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .caption2) private var logFontSize: CGFloat = 11

    private let service = DockerService.shared

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemBackground)

                ScrollView {
                    if displayedLogs.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "doc.text")
                                .font(.largeTitle)
                                .foregroundStyle(.tertiary)
                            if isLoading {
                                ProgressView("正在读取日志…")
                            } else {
                                Text("暂无日志")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                    } else {
                        Text(displayedLogs)
                            .font(.system(size: logFontSize, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
            }
            .navigationTitle("日志 · \(containerName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .task {
                await refresh()
                startAutoRefresh()
            }
            .onDisappear { stopAutoRefresh() }
            .sheet(isPresented: $showShare) {
                if let url = shareURL {
                    ActivityShareSheet(items: [url])
                        .presentationDetents([.medium])
                }
            }
        }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                // 时间范围（1Panel 同款）
                Section("时间范围") {
                    ForEach(LogRange.allCases) { item in
                        Button {
                            range = item
                            Task { await refresh() }
                        } label: {
                            Label(item.rawValue, systemImage: range == item ? "checkmark" : "clock")
                        }
                    }
                }
                Section {
                    Button {
                        autoRefresh.toggle()
                        if autoRefresh { startAutoRefresh() } else { stopAutoRefresh() }
                    } label: {
                        Label(autoRefresh ? "停止实时跟随" : "开启实时跟随",
                              systemImage: autoRefresh ? "pause" : "play")
                    }
                    Button { Task { await refresh() } } label: {
                        Label("立即刷新", systemImage: "arrow.clockwise")
                    }
                    Button { Task { await downloadLogs() } } label: {
                        Label("下载日志", systemImage: "square.and.arrow.down")
                    }
                    Button { copyLogs() } label: {
                        Label("复制全部日志", systemImage: "doc.on.doc")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        ToolbarItem(placement: .topBarLeading) {
            Button("完成") { dismiss() }
        }
    }

    // MARK: - 数据与逻辑

    private var displayedLogs: String {
        let query = keyword.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return logs }
        let matched = logs.split(separator: "\n").filter {
            $0.localizedCaseInsensitiveContains(query)
        }
        return matched.joined(separator: "\n")
    }

    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let result: Result<String, DockerError>
        if let since = range.sinceArg {
            result = await service.fetchLogs(containerID: containerID, since: since)
        } else {
            result = await service.fetchLogs(containerID: containerID, tail: 300)
        }
        if case .success(let text) = result {
            logs = text
        }
    }

    /// 拉取全部日志写入临时文件，弹出系统分享面板导出（1Panel 下载能力）。
    private func downloadLogs() async {
        let result = await service.fetchAllLogs(containerID: containerID)
        guard case .success(let text) = result, !text.isEmpty else { return }
        let fileName = "\(containerName.replacingOccurrences(of: "/", with: "_"))-logs.txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        await MainActor.run {
            shareURL = url
            showShare = true
        }
    }

    // MARK: - 自动刷新（定时器）

    private func startAutoRefresh() {
        refreshTimer.start(interval: 3) {
            Task { await self.refresh() }
        }
    }

    private func stopAutoRefresh() {
        refreshTimer.stop()
    }

    private func copyLogs() {
        UIPasteboard.general.string = logs
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            copied = false
        }
    }
}

/// 简单的定时器持有者，避免 @State 存 Timer 造成视图反复更新。
private final class TimerHolder {
    private var timer: Timer?
    private var onFire: (() -> Void)?

    func start(interval: TimeInterval, _ action: @escaping () -> Void) {
        stop()
        onFire = action
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.onFire?()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit { stop() }
}
