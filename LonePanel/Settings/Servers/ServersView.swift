import SwiftUI

/// 「我的服务器」列表页。空状态、标注、左滑操作、临时切换都在此页完成。
/// 只依赖根 Core 的 ServerSession 与 Settings/Core 的会话实现，不引用其他功能模块。
struct ServersView: View {
    @ObservedObject private var session = ServerSession.shared
    @State private var servers: [Server] = []
    @State private var defaultID: UUID?
    @State private var showAdd = false
    @State private var editing: Server?
    @State private var pendingDelete: Server?
    @State private var errorMessage: String?

    private let sessionImpl = SettingsServerSession.shared

    var body: some View {
        List {
            if servers.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text(L10n.t("No servers yet. Tap + to add one."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 240)
                .listRowSeparator(.hidden)
            } else {
                ForEach(servers) { server in
                    serverRow(server)
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                editing = server
                            } label: {
                                Label(L10n.t("Edit"), systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if servers.count >= 2 {
                                Button {
                                    sessionImpl.setDefault(server.id)
                                    reload()
                                } label: {
                                    Label(L10n.t("Set as Default"), systemImage: "star")
                                }
                                .tint(.orange)
                            }
                            Button(role: .destructive) {
                                pendingDelete = server
                            } label: {
                                Label(L10n.t("Delete"), systemImage: "trash")
                            }
                        }
                }
            }
        }
        .navigationTitle(L10n.t("My Servers"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.t("Add Server"))
            }
        }
        .sheet(isPresented: $showAdd) {
            ServerFormView(server: nil) { reload() }
        }
        .sheet(item: $editing) { server in
            ServerFormView(server: server) { reload() }
        }
        .alert(L10n.t("Delete Server"), isPresented: deleteAlertBinding) {
            Button(L10n.t("Cancel"), role: .cancel) { pendingDelete = nil }
            Button(L10n.t("Delete"), role: .destructive) {
                if let target = pendingDelete {
                    sessionImpl.remove(target.id)
                    reload()
                }
                pendingDelete = nil
            }
        } message: {
            Text(L10n.f("Delete \"%@\"? Its credential will also be removed from Keychain. This cannot be undone.", String(describing: (pendingDelete?.name ?? ""))))
        }
        .alert(L10n.t("Notice"), isPresented: errorAlertBinding) {
            Button(L10n.t("OK"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear { reload() }
    }

    @ViewBuilder
    private func serverRow(_ server: Server) -> some View {
        Button {
            sessionImpl.selectTemporarily(server.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayName(server))
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text("\(server.username)@\(server.host):\(server.port)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if session.currentServer?.id == server.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .accessibilityLabel(L10n.t("Current Connection"))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 默认与当前同一台时只标（默认）。
    private func displayName(_ server: Server) -> String {
        let isDefault = server.id == defaultID
        let isCurrent = session.currentServer?.id == server.id
        if isDefault { return "\(server.name) (default)" }
        if isCurrent { return "\(server.name) (current)" }
        return server.name
    }

    private func reload() {
        servers = sessionImpl.servers
        defaultID = sessionImpl.defaultID
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }
}
