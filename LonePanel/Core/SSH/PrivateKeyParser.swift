import Foundation
import Crypto
import NIOSSH

/// 私钥解析错误。`errorDescription` 均为可直接展示给用户的人话。
enum PrivateKeyError: LocalizedError {
    case empty
    case notPEM
    case undecodable
    case encrypted(String)
    case unsupportedAlgorithm(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "私钥内容为空，请把完整的密钥文件粘贴进来"
        case .notPEM:
            return "无法识别私钥格式，请使用 PEM 格式的私钥（以 -----BEGIN 开头）"
        case .undecodable:
            return "私钥的 Base64 内容无效，请检查是否复制完整、有没有多余字符"
        case .encrypted(let kind):
            return "这把私钥经过加密（\(kind)），SSH 内核无法直接使用。请先解密，例如执行：ssh-keygen -p -f 你的密钥文件"
        case .unsupportedAlgorithm(let name):
            return "暂不支持 \(name) 私钥用于 SSH 登录，请改用 Ed25519 或 ECDSA 密钥（ssh-keygen -t ed25519）"
        case .malformed(let detail):
            return "私钥内容不完整或格式有误（\(detail)），请确认复制了整份密钥文件"
        }
    }
}

/// 私钥解析器：自动识别并解析 OpenSSH 新格式、PKCS#1、PKCS#8、SEC1 EC 等常见 PEM 私钥，
/// 提取 Ed25519 / ECDSA（P-256/384/521）标量构造 NIOSSHPrivateKey。
///
/// 说明：SwiftNIO SSH 的私钥引擎仅支持 Ed25519 与 ECDSA，不含 RSA/DSA；
/// 因此 RSA/DSA 虽能被本解析器识别，但会给出明确的人话提示，不会伪装成可用。
enum PrivateKeyParser {
    static func parse(_ text: String) throws -> NIOSSHPrivateKey {
        let pem = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pem.isEmpty else { throw PrivateKeyError.empty }
        guard pem.contains("-----BEGIN") else { throw PrivateKeyError.notPEM }

        let (label, body) = try extractPEM(pem)
        guard let data = Data(base64Encoded: body), !data.isEmpty else {
            throw PrivateKeyError.undecodable
        }
        let bytes = [UInt8](data)

        switch label {
        case "OPENSSH PRIVATE KEY":
            return try parseOpenSSH(bytes)
        case "PRIVATE KEY":                 // PKCS#8 (RFC 5208 / 8410)
            return try parsePKCS8(bytes)
        case "EC PRIVATE KEY":              // SEC1 (RFC 5915)
            return try parseSEC1(bytes)
        case "RSA PRIVATE KEY":             // PKCS#1 RSA
            throw PrivateKeyError.unsupportedAlgorithm("RSA（PKCS#1）")
        case "ENCRYPTED PRIVATE KEY":       // 加密的 PKCS#8
            throw PrivateKeyError.encrypted("PKCS#8")
        case "DSA PRIVATE KEY":
            throw PrivateKeyError.unsupportedAlgorithm("DSA")
        default:
            throw PrivateKeyError.malformed("未知的 PEM 标签 \(label)")
        }
    }

    // MARK: - PEM 提取

    /// 取第一个 PEM 块的标签与 Base64 正文；识别传统 `Proc-Type: 4,ENCRYPTED` 加密头。
    private static func extractPEM(_ pem: String) throws -> (String, String) {
        var label: String?
        var bodyLines: [String] = []
        var inBlock = false

        for rawLine in pem.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("-----BEGIN ") && line.hasSuffix("-----") {
                if inBlock { break }
                let start = line.index(line.startIndex, offsetBy: 11) // "-----BEGIN "
                let end = line.index(line.endIndex, offsetBy: -5)     // "-----"
                label = String(line[start..<end])
                inBlock = true
                continue
            }
            if line.hasPrefix("-----END ") { break }
            guard inBlock else { continue }
            if line.localizedCaseInsensitiveContains("Proc-Type: 4,ENCRYPTED") ||
                line.hasPrefix("DEK-Info:") {
                throw PrivateKeyError.encrypted("传统 PEM")
            }
            if !line.isEmpty && !line.contains(":") {
                bodyLines.append(line)
            }
        }

        guard let l = label else { throw PrivateKeyError.notPEM }
        return (l, bodyLines.joined())
    }

    // MARK: - OpenSSH 新格式 (openssh-key-v1)

    private static func parseOpenSSH(_ bytes: [UInt8]) throws -> NIOSSHPrivateKey {
        var reader = SSHReader(bytes)
        let magic = Array("openssh-key-v1\0".utf8)
        guard reader.read(count: magic.count) == magic else {
            throw PrivateKeyError.malformed("缺少 openssh-key-v1 标识")
        }
        let cipher = try reader.readUTF8String()
        if cipher != "none" {
            throw PrivateKeyError.encrypted("OpenSSH（\(cipher)）")
        }
        _ = try reader.readUTF8String() // kdfname
        _ = try reader.readUTF8String() // kdfoptions
        let keyCount = try reader.readUInt32()
        guard keyCount == 1 else {
            throw PrivateKeyError.malformed("私钥文件包含 \(keyCount) 个密钥")
        }
        _ = try reader.readBytes()        // public key blob
        let privateBlob = try reader.readBytes()

        var payload = SSHReader(privateBlob)
        _ = try payload.readUInt32()      // checkint 1
        _ = try payload.readUInt32()      // checkint 2
        let keyType = try payload.readUTF8String()

        switch keyType {
        case "ssh-ed25519":
            _ = try payload.readBytes()   // public key (32 bytes)
            // 私钥部分为 64 字节：前 32 字节是种子，后 32 字节是公钥。
            // 旧实现误把整个 64 字节当作种子并要求 32 字节，导致必然失败。
            let privateKeyBlob = try payload.readBytes()
            guard privateKeyBlob.count >= 32 else {
                throw PrivateKeyError.malformed("Ed25519 私钥数据只有 \(privateKeyBlob.count) 字节")
            }
            return try makeEd25519(Array(privateKeyBlob.prefix(32)))
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            _ = try payload.readUTF8String() // curve name
            _ = try payload.readBytes()      // public point
            let scalar = try payload.readBytes() // mpint scalar
            let oid: [UInt8]
            switch keyType {
            case "ecdsa-sha2-nistp256": oid = CurveOID.p256
            case "ecdsa-sha2-nistp384": oid = CurveOID.p384
            default:                        oid = CurveOID.p521
            }
            return try makeEC(scalar: scalar, curveOID: oid)
        case "ssh-rsa":
            throw PrivateKeyError.unsupportedAlgorithm("RSA")
        case "ssh-dss":
            throw PrivateKeyError.unsupportedAlgorithm("DSA")
        default:
            throw PrivateKeyError.unsupportedAlgorithm(keyType)
        }
    }

    // MARK: - PKCS#8

    private static func parsePKCS8(_ bytes: [UInt8]) throws -> NIOSSHPrivateKey {
        var der = DERReader(bytes)
        let seq = try der.expect(0x30, "PrivateKeyInfo")
        var info = DERReader(seq)
        _ = try info.expect(0x02, "版本号")                 // version
        let algSeq = try info.expect(0x30, "AlgorithmIdentifier")
        let privateOctet = try info.expect(0x04, "私钥数据")

        var alg = DERReader(algSeq)
        let oid = try alg.expect(0x06, "算法 OID")

        if oid == CurveOID.ed25519 {
            // RFC 8410：privateKey OCTET STRING 内还是一个包裹种子的 OCTET STRING。
            var pk = DERReader(privateOctet)
            let seed = try pk.expect(0x04, "Ed25519 种子")
            return try makeEd25519(seed)
        } else if oid == CurveOID.ecPublicKey {
            var curveOID: [UInt8]?
            if !alg.isAtEnd, let param = try? alg.readTLV(), param.tag == 0x06 {
                curveOID = param.value
            }
            return try parseECPrivateKey(privateOctet, curveOID: curveOID)
        } else if oid == CurveOID.rsa {
            throw PrivateKeyError.unsupportedAlgorithm("RSA（PKCS#8）")
        } else {
            throw PrivateKeyError.unsupportedAlgorithm("未知算法")
        }
    }

    // MARK: - SEC1 EC 私钥

    private static func parseSEC1(_ bytes: [UInt8]) throws -> NIOSSHPrivateKey {
        try parseECPrivateKey(bytes, curveOID: nil)
    }

    private static func parseECPrivateKey(_ bytes: [UInt8], curveOID: [UInt8]?) throws -> NIOSSHPrivateKey {
        var der = DERReader(bytes)
        let seq = try der.expect(0x30, "ECPrivateKey")
        var inner = DERReader(seq)
        _ = try inner.expect(0x02, "EC 版本号")
        let scalar = try inner.expect(0x04, "EC 私钥标量")

        var resolvedOID = curveOID
        // 在可选的 parameters [0] 里找曲线 OID（PKCS#8 通常由 AlgorithmIdentifier 提供）。
        while !inner.isAtEnd, let tlv = try? inner.readTLV() {
            if tlv.tag == 0xA0 {
                var params = DERReader(tlv.value)
                if let curve = try? params.readTLV(), curve.tag == 0x06 {
                    resolvedOID = curve.value
                }
            }
        }
        guard let oid = resolvedOID else {
            throw PrivateKeyError.malformed("缺少椭圆曲线标识")
        }
        return try makeEC(scalar: scalar, curveOID: oid)
    }

    // MARK: - 构造 NIOSSHPrivateKey

    private static func makeEd25519(_ seed: [UInt8]) throws -> NIOSSHPrivateKey {
        guard seed.count == 32 else {
            throw PrivateKeyError.malformed("Ed25519 种子应为 32 字节，实际 \(seed.count) 字节")
        }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(seed))
        return NIOSSHPrivateKey(ed25519Key: key)
    }

    private static func makeEC(scalar: [UInt8], curveOID: [UInt8]) throws -> NIOSSHPrivateKey {
        switch curveOID {
        case CurveOID.p256:
            let raw = try normalizeScalar(scalar, to: 32, name: "P-256")
            return NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: Data(raw)))
        case CurveOID.p384:
            let raw = try normalizeScalar(scalar, to: 48, name: "P-384")
            return NIOSSHPrivateKey(p384Key: try P384.Signing.PrivateKey(rawRepresentation: Data(raw)))
        case CurveOID.p521:
            let raw = try normalizeScalar(scalar, to: 66, name: "P-521")
            return NIOSSHPrivateKey(p521Key: try P521.Signing.PrivateKey(rawRepresentation: Data(raw)))
        default:
            throw PrivateKeyError.unsupportedAlgorithm("该椭圆曲线")
        }
    }

    /// SSH mpint / DER INTEGER 常带前导 0（表示正数），需去掉再左补齐到曲线要求的固定长度。
    private static func normalizeScalar(_ raw: [UInt8], to length: Int, name: String) throws -> [UInt8] {
        var value = Array(raw)
        while value.count > length, value.first == 0 { value.removeFirst() }
        guard value.count <= length else {
            throw PrivateKeyError.malformed("\(name) 标量长度 \(value.count) 超过 \(length) 字节")
        }
        while value.count < length { value.insert(0, at: 0) }
        return value
    }
}

// MARK: - 已知 OID（DER 内容字节）

private enum CurveOID {
    static let ed25519: [UInt8] = [0x2B, 0x65, 0x70]                                   // 1.3.101.112
    static let ecPublicKey: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]        // 1.2.840.10045.2.1
    static let p256: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]         // prime256v1
    static let p384: [UInt8] = [0x2B, 0x81, 0x04, 0x00, 0x22]                           // secp384r1
    static let p521: [UInt8] = [0x2B, 0x81, 0x04, 0x00, 0x23]                           // secp521r1
    static let rsa: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]     // rsaEncryption
}

// MARK: - 极简 DER (TLV) 读取器

private struct DERReader {
    let bytes: [UInt8]
    var offset: Int = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }
    var isAtEnd: Bool { offset >= bytes.count }

    mutating func readTLV() throws -> (tag: UInt8, value: [UInt8]) {
        guard offset + 2 <= bytes.count else {
            throw PrivateKeyError.malformed("DER 数据意外结束")
        }
        let tag = bytes[offset]; offset += 1
        let first = bytes[offset]; offset += 1
        var length = 0
        if first & 0x80 == 0 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7F)
            guard count > 0, count <= 4, offset + count <= bytes.count else {
                throw PrivateKeyError.malformed("DER 长度字段无效")
            }
            for _ in 0..<count {
                length = (length << 8) | Int(bytes[offset]); offset += 1
            }
        }
        guard length <= bytes.count - offset else {
            throw PrivateKeyError.malformed("DER 内容长度超出范围")
        }
        let value = Array(bytes[offset..<(offset + length)])
        offset += length
        return (tag, value)
    }

    mutating func expect(_ tag: UInt8, _ name: String) throws -> [UInt8] {
        let tlv = try readTLV()
        guard tlv.tag == tag else {
            throw PrivateKeyError.malformed("期望 \(name)")
        }
        return tlv.value
    }
}

// MARK: - SSH 二进制读取器（uint32 / string / blob）

private struct SSHReader {
    let bytes: [UInt8]
    var offset: Int = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

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
        guard length <= UInt32(bytes.count - offset) else {
            throw PrivateKeyError.malformed("长度字段超出数据范围")
        }
        return read(count: Int(length))
    }

    mutating func readUTF8String() throws -> String {
        String(decoding: try readBytes(), as: UTF8.self)
    }
}
