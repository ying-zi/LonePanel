import Foundation

/// Settings 私有的服务器业务模型。凭证本体不在此，只有钥匙串索引键。
/// 根 Core 不认识这个类型，模块间不互相引用。
struct Server: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var authKind: ServerAuthKind
    var credentialKey: String
}
