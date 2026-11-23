import Foundation

/// 认证方式。根 Core 只描述连接所需的类型，不保存任何服务器业务配置。
enum ServerAuthKind: String, Codable, Sendable {
    case password
    case privateKey
}

/// 只读的连接快照：所有模块通过它连接服务器，不直接持有服务器业务对象。
/// 凭证本体不在其中，仅携带钥匙串索引键。
struct ServerConnectionInfo: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let name: String
    let host: String
    let port: Int
    let username: String
    let authKind: ServerAuthKind
    let credentialKey: String
}
