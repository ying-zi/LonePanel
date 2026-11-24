import Foundation

/// SFTP v3 数据包：1 字节类型 + 载荷。
struct SFTPPacket {
    let type: UInt8
    let payload: [UInt8]

    init(type: UInt8, payload: [UInt8]) {
        self.type = type
        self.payload = payload
    }

    /// 4 字节长度前缀 + 类型 + 载荷。长度不含自身。
    var framed: [UInt8] {
        var bytes: [UInt8] = []
        let bodyLength = 1 + payload.count
        bytes.append(contentsOf: SFTPWire.be32(UInt32(bodyLength)))
        bytes.append(type)
        bytes.append(contentsOf: payload)
        return bytes
    }
}

/// SFTP v3 消息类型。
enum SFTPMessage {
    static let initialize: UInt8 = 1
    static let version: UInt8 = 2
    static let open: UInt8 = 3
    static let close: UInt8 = 4
    static let read: UInt8 = 5
    static let write: UInt8 = 6
    static let stat: UInt8 = 7
    static let lstat: UInt8 = 8
    static let opendir: UInt8 = 11
    static let readdir: UInt8 = 12
    static let remove: UInt8 = 13
    static let mkdir: UInt8 = 14
    static let rmdir: UInt8 = 15
    static let realpath: UInt8 = 16
    static let rename: UInt8 = 18
    static let status: UInt8 = 101
    static let handle: UInt8 = 102
    static let data: UInt8 = 103
    static let name: UInt8 = 104
    static let attrs: UInt8 = 105
}

/// SFTP 状态码（v3）。
enum SFTPStatusCode {
    static let ok: UInt32 = 0
    static let eof: UInt32 = 1
}

/// 打开文件的标志位。
enum SFTPOpenFlag {
    static let read: UInt32 = 0x00000001
    static let write: UInt32 = 0x00000002
    static let append: UInt32 = 0x00000004
    static let trunc: UInt32 = 0x00000008
    // SFTP v3：CREAT=0x10，EXCL=0x20。此前误把 0x20 当作 creat，
    // 导致覆盖已存在文件时带了 EXCL 标志被服务器拒绝（编辑保存/复制同名文件失败）。
    static let creat: UInt32 = 0x00000010
    static let excl: UInt32 = 0x00000020
}

/// 文件条目（浏览器列表与导航共用）。
struct RemoteFile: Identifiable, Hashable {
    let name: String
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: Int64
    let modified: Date?
    let permissions: UInt32
    /// 属主 UID / GID（服务器提供时填充，供详情页属性展示）。
    var uid: UInt32? = nil
    var gid: UInt32? = nil

    var id: String { path }

    /// 权限的文字表示，如 -rw-r--r--。
    var permissionText: String {
        let bits: [Character] = [
            isDirectory ? "d" : (isSymlink ? "l" : "-"),
            permissions & 0o400 != 0 ? "r" : "-",
            permissions & 0o200 != 0 ? "w" : "-",
            permissions & 0o100 != 0 ? "x" : "-",
            permissions & 0o040 != 0 ? "r" : "-",
            permissions & 0o020 != 0 ? "w" : "-",
            permissions & 0o010 != 0 ? "x" : "-",
            permissions & 0o004 != 0 ? "r" : "-",
            permissions & 0o002 != 0 ? "w" : "-",
            permissions & 0o001 != 0 ? "x" : "-",
        ]
        return String(bits)
    }
}

/// 把任意路径安全包成 shell 单引号字符串，供远端命令使用，避免空格/特殊字符注入。
func shellQuote(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// 文件属性（v3 ATTRS）。
struct FileAttributes {
    var flags: UInt32 = 0
    var size: UInt64?
    var uid: UInt32?
    var gid: UInt32?
    var permissions: UInt32?
    var atime: UInt32?
    var mtime: UInt32?

    /// 空属性：MKDIR 等场景使用。
    var encoded: [UInt8] { SFTPWire.be32(0) }
}

/// SFTP 操作错误（人话描述）。
enum SFTPError: LocalizedError {
    case notConnected
    case malformed(String)
    case status(code: UInt32, message: String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "尚未连接到服务器，请稍候重试"
        case .malformed(let text):
            return "服务器返回的数据无法解析（\(text)）"
        case .status(let code, let message):
            if message.isEmpty {
                switch code {
                case 1: return "没有更多内容了"
                case 2: return "文件或目录不存在"
                case 3: return "没有权限访问该位置"
                case 4: return "服务器拒绝了这次操作"
                default: return "SFTP 操作失败（代码 \(code)）"
                }
            }
            return "SFTP 操作失败：\(message)"
        }
    }
}

/// 字节序编解码工具。
enum SFTPWire {
    static func be32(_ value: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ]
    }

    static func be64(_ value: UInt64) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: value >> 56),
            UInt8(truncatingIfNeeded: value >> 48),
            UInt8(truncatingIfNeeded: value >> 40),
            UInt8(truncatingIfNeeded: value >> 32),
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ]
    }

    static func uint32(_ bytes: [UInt8], at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { throw SFTPError.malformed("数据过短") }
        return (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16) |
               (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }

    static func uint64(_ bytes: [UInt8], at offset: Int) throws -> UInt64 {
        guard offset >= 0, offset + 8 <= bytes.count else { throw SFTPError.malformed("数据过短") }
        var value: UInt64 = 0
        for index in offset..<(offset + 8) { value = (value << 8) | UInt64(bytes[index]) }
        return value
    }
}

/// 载荷写入器。
struct PayloadWriter {
    private(set) var bytes: [UInt8] = []

    mutating func uint32(_ value: UInt32) { bytes.append(contentsOf: SFTPWire.be32(value)) }
    mutating func uint64(_ value: UInt64) { bytes.append(contentsOf: SFTPWire.be64(value)) }

    mutating func string(_ value: String) {
        blob(Array(value.utf8))
    }

    /// 写 SFTP string：4 字节长度 + 原始字节（可承载任意二进制数据）。
    mutating func blob(_ value: [UInt8]) {
        uint32(UInt32(value.count))
        bytes.append(contentsOf: value)
    }

    mutating func raw(_ value: [UInt8]) { bytes.append(contentsOf: value) }
}

/// 载荷读取器。
struct PayloadReader {
    private let bytes: [UInt8]
    private var offset: Int

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.offset = 0
    }

    var isAtEnd: Bool { offset >= bytes.count }

    mutating func uint32() throws -> UInt32 {
        let value = try SFTPWire.uint32(bytes, at: offset)
        offset += 4
        return value
    }

    mutating func uint64() throws -> UInt64 {
        let value = try SFTPWire.uint64(bytes, at: offset)
        offset += 8
        return value
    }

    mutating func data() throws -> [UInt8] {
        let length = Int(try uint32())
        guard length >= 0, offset + length <= bytes.count else { throw SFTPError.malformed("长度越界") }
        let value = Array(bytes[offset..<(offset + length)])
        offset += length
        return value
    }

    mutating func string() throws -> String {
        String(decoding: try data(), as: UTF8.self)
    }

    mutating func attributes() throws -> FileAttributes {
        var attrs = FileAttributes()
        attrs.flags = try uint32()

        if attrs.flags & 0x00000001 != 0 { attrs.size = try uint64() }   // SSH_FILEXFER_ATTR_SIZE
        if attrs.flags & 0x00000002 != 0 {                                // UID/GID
            attrs.uid = try uint32()
            attrs.gid = try uint32()
        }
        if attrs.flags & 0x00000004 != 0 { attrs.permissions = try uint32() } // PERMISSIONS
        if attrs.flags & 0x00000008 != 0 {                                // ACMODTIME
            attrs.atime = try uint32()
            attrs.mtime = try uint32()
        }
        if attrs.flags & 0x80000000 != 0 {                                // EXTENDED
            let count = try uint32()
            for _ in 0..<count {
                _ = try data()
                _ = try data()
            }
        }
        return attrs
    }
}
