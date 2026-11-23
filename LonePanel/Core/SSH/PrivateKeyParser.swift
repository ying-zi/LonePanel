import Foundation
import Crypto
import NIOSSH

/// 私钥解析错误，直接作为「测试连接」的失败原因展示。
enum PrivateKeyError: LocalizedError {
    case malformed(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .malformed(let text): return "私钥格式错误：\(text)"
        case .unsupported(let text): return "暂不支持：\(text)"
        }
    }
}

/// 把常见的未加密 OpenSSH 私钥（ssh-keygen 默认格式）解析为 NIOSSHPrivateKey。
/// 支持 Ed25519、ECDSA P-256/384/521；加密私钥与 RSA 给出明确提示。
enum PrivateKeyParser {
    static func parse(_ text: String) throws -> NIOSSHPrivateKey {
        let pem = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = pem
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.contains("-----") && !$0.isEmpty }
            .joined()

        guard !body.isEmpty, let data = Data(base64Encoded: body) else {
            throw PrivateKeyError.malformed("内容不是有效的 PEM Base64")
        }

        var reader = ByteReader(bytes: [UInt8](data))
        let magic = Array("openssh-key-v1\0".utf8)
        guard reader.read(count: magic.count) == magic else {
            throw PrivateKeyError.unsupported("仅支持 openssh-key-v1 格式，PKCS#8 私钥请改用 OpenSSH 格式导出")
        }

        let cipher = try reader.readUTF8String()
        if cipher != "none" {
            throw PrivateKeyError.unsupported("加密私钥暂不支持，请提供未加密的私钥")
        }
        _ = try reader.readUTF8String() // kdfname
        _ = try reader.readUTF8String() // kdfoptions
        let keyCount = try reader.readUInt32()
        guard keyCount == 1 else {
            throw PrivateKeyError.unsupported("该私钥文件包含多个密钥")
        }
        _ = try reader.readBytes() // public key blob
        let privateBlob = try reader.readBytes()

        var payload = ByteReader(bytes: privateBlob)
        _ = try payload.readUInt32() // checkint 1
        _ = try payload.readUInt32() // checkint 2
        let keyType = try payload.readUTF8String()

        switch keyType {
        case "ssh-ed25519":
            _ = try payload.readBytes() // public key
            let seed = try payload.readBytes()
            guard seed.count == 32 else {
                throw PrivateKeyError.malformed("Ed25519 种子长度应为 32 字节")
            }
            return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: Data(seed)))
        case "ecdsa-sha2-nistp256":
            _ = try payload.readUTF8String() // curve name
            let scalar = try payload.readBytes()
            return NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: Data(scalar)))
        case "ecdsa-sha2-nistp384":
            _ = try payload.readUTF8String()
            let scalar = try payload.readBytes()
            return NIOSSHPrivateKey(p384Key: try P384.Signing.PrivateKey(rawRepresentation: Data(scalar)))
        case "ecdsa-sha2-nistp521":
            _ = try payload.readUTF8String()
            let scalar = try payload.readBytes()
            return NIOSSHPrivateKey(p521Key: try P521.Signing.PrivateKey(rawRepresentation: Data(scalar)))
        case "ssh-rsa":
            throw PrivateKeyError.unsupported("RSA 私钥不受 SwiftNIO SSH 支持，请使用 Ed25519 密钥")
        default:
            throw PrivateKeyError.unsupported("密钥类型 \(keyType)，支持 Ed25519 与 ECDSA P-256/384/521")
        }
    }
}

private struct ByteReader {
    let bytes: [UInt8]
    var offset: Int = 0

    mutating func read(count: Int) -> [UInt8] {
        let end = min(offset + count, bytes.count)
        defer { offset = end }
        return Array(bytes[offset..<end])
    }

    mutating func readUInt32() throws -> UInt32 {
        let raw = read(count: 4)
        guard raw.count == 4 else { throw PrivateKeyError.malformed("数据意外结束") }
        return (UInt32(raw[0]) << 24) | (UInt32(raw[1]) << 16) | (UInt32(raw[2]) << 8) | UInt32(raw[3])
    }

    mutating func readBytes() throws -> [UInt8] {
        let length = try readUInt32()
        guard offset <= bytes.count, length <= UInt32(bytes.count - offset) else {
            throw PrivateKeyError.malformed("长度字段超出数据范围")
        }
        return read(count: Int(length))
    }

    mutating func readUTF8String() throws -> String {
        String(decoding: try readBytes(), as: UTF8.self)
    }
}
