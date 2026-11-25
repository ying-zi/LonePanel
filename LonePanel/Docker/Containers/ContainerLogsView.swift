import SwiftUI

/// 容器日志页：进入即拉取尾部日志，可自动刷新、搜索关键词、复制全部。
struct ContainerLogsView: View {
    let containerID: String
    let containerName: String

    @State private var logs = ""
    @State private var isLoading = false
    @State private var autoRefresh = true
    @State private var keyword = ""
    @State private var copied = false
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
        }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    autoRefresh.toggle()
                    if autoRefresh { startAutoRefresh() } else { stopAutoRefresh() }
                } label: {
                    Label(autoRefresh ? "停止自动刷新" : "开启自动刷新",
                          systemImage: autoRefresh ? "pause" : "play")
                }
                Button { Task { await refresh() } } label: {
                    Label("立即刷新", systemImage: "arrow.clockwise")
                }
                Button { copyLogs() } label: {
                    Label("复制全部日志", systemImage: "doc.on.doc")
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
        let result = await service.fetchLogs(containerID: containerID, tail: 300)
        if case .success(let text) = result {
            logs = text
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
