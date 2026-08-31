//
//  TeslaCrypto.swift
//  TeslaDash
//
//  Tesla BLE 的密码学部分：
//    · P-256 ECDH  →  SHA1(shared) 前 16 字节  = AES-128 会话密钥
//    · AES-GCM 请求/响应加密，AAD = SHA256(AD TLV 缓冲)
//  与 tesla-ble (yoziru) / 官方 vehicle-command 协议一致。
//

import Foundation
import CryptoKit

enum TeslaCrypto {

    // MARK: - 常量

    static let keySize = 16
    static let epochSize = 16
    static let nonceSize = 12
    static let tagSize = 16

    /// Signatures.Tag
    enum ADTag: UInt8 {
        case signatureType = 0
        case domain        = 1
        case personalization = 2
        case epoch         = 3
        case expiresAt     = 4
        case counter       = 5
        case challenge     = 6
        case flags         = 7
        case requestHash   = 8
        case fault         = 9
        case end           = 255
    }

    /// Signatures.SignatureType
    enum SigType: UInt8 {
        case aesGcm            = 0
        case aesGcmPersonalized = 5
        case hmac              = 6
        case hmacPersonalized  = 8
        case aesGcmResponse    = 9
    }

    // MARK: - 会话密钥

    /// ECDH(私钥, 车端 65 字节公钥) → SHA1 → 前 16 字节
    static func sessionKey(privateKey: P256.KeyAgreement.PrivateKey,
                           vehiclePublicKey: Data) throws -> Data {
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: vehiclePublicKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let secret = shared.withUnsafeBytes { Data($0) }          // 32 字节 X 坐标
        let digest = Insecure.SHA1.hash(data: secret)             // 20 字节
        return Data(digest.prefix(keySize))                       // 取前 16 字节
    }

    /// keyId = SHA1(公钥) 前 4 字节
    static func keyId(publicKey: Data) -> Data {
        let digest = Insecure.SHA1.hash(data: publicKey)
        return Data(digest.prefix(4))
    }

    // MARK: - AD（Additional Data）TLV 缓冲

    /// 按 Tesla 的 tag-length-value 规则拼出 AD 缓冲，末尾固定加 0xFF 终结字节。
    static func adBuffer(signatureType: SigType,
                         domain: UInt8,
                         vin: String,
                         epoch: Data?,
                         expiresAt: UInt32?,
                         counter: UInt32,
                         flags: UInt32,
                         requestHash: Data?,
                         fault: UInt32?) -> Data {
        var out = Data()

        func append(_ tag: ADTag, _ value: Data) {
            precondition(value.count <= 255, "AD TLV 单段不得超过 255 字节")
            out.append(tag.rawValue)
            out.append(UInt8(truncatingIfNeeded: value.count))
            out.append(value)
        }

        func be(_ v: UInt32) -> Data {
            var x = v.bigEndian
            return withUnsafeBytes(of: &x) { Data($0) }
        }

        let isResponse = (signatureType == .aesGcmResponse)

        append(.signatureType, Data([signatureType.rawValue]))
        append(.domain, Data([domain]))
        append(.personalization, Data(String(vin.prefix(17)).utf8))

        // epoch + expires_at 只出现在请求里
        if !isResponse {
            append(.epoch, epoch ?? Data(count: epochSize))
            append(.expiresAt, be(expiresAt ?? 0))
        }

        append(.counter, be(counter))

        // 响应必须带 flags；请求仅在非零时带（向后兼容）
        if isResponse || flags > 0 {
            append(.flags, be(flags))
        }

        if isResponse {
            if let rh = requestHash, !rh.isEmpty {
                append(.requestHash, rh)
            }
            append(.fault, be(fault ?? 0))
        }

        out.append(ADTag.end.rawValue)
        return out
    }

    /// AAD = SHA256(AD 缓冲)
    static func aad(for ad: Data) -> Data {
        Data(SHA256.hash(data: ad))
    }

    // MARK: - HMAC-SHA256（会话信息完整性校验）

    /// HMAC-SHA256(key, data)
    static func hmacSHA256(key: Data, data: Data) -> Data {
        let auth = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(auth)
    }

    /// 会话信息校验密钥 = HMAC-SHA256(会话密钥, "session info")
    static func sessionInfoKey(from sessionKey: Data) -> Data {
        hmacSHA256(key: sessionKey, data: Data("session info".utf8))
    }

    /// 拼接会话信息 HMAC 的元数据 TLV：
    ///   TAG_SIGNATURE_TYPE(0) = HMAC(6) → TAG_PERSONALIZATION(2) = VIN → TAG_CHALLENGE(6) = 请求 UUID → 0xFF
    static func sessionInfoMetadata(vin: String, challenge: Data) -> Data {
        var out = Data()
        func append(_ tag: ADTag, _ value: Data) {
            out.append(tag.rawValue)
            out.append(UInt8(truncatingIfNeeded: min(value.count, 255)))
            out.append(value.prefix(255))
        }
        append(.signatureType, Data([SigType.hmac.rawValue]))
        append(.personalization, Data(vin.prefix(17).utf8))
        append(.challenge, challenge)
        out.append(ADTag.end.rawValue)
        return out
    }

    /// 校验车辆回传的 session_info HMAC 标签。
    /// - Parameters:
    ///   - sessionInfo: 字段 15 的原始字节（未解析）
    ///   - tag: signature_data.session_info_tag.tag
    ///   - sessionKey: 已建立的 16 字节会话密钥
    static func verifySessionInfoTag(sessionInfo: Data,
                                     tag: Data,
                                     vin: String,
                                     challenge: Data,
                                     sessionKey: Data) -> Bool {
        let key = sessionInfoKey(from: sessionKey)
        var input = sessionInfoMetadata(vin: vin, challenge: challenge)
        input.append(sessionInfo)
        let expected = hmacSHA256(key: key, data: input)
        // 车辆可能回 32 字节完整标签或截断的 16 字节
        if tag.count == expected.count { return constantTimeEqual(tag, expected) }
        if tag.count == 16 { return constantTimeEqual(tag, expected.prefix(16)) }
        return false
    }

    /// 常量时间比较，避免时序侧信道
    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    // MARK: - AES-GCM

    static func randomNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: nonceSize)
        _ = SecRandomCopyBytes(kSecRandomDefault, nonceSize, &bytes)
        return Data(bytes)
    }

    static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    struct Sealed {
        let ciphertext: Data
        let tag: Data
        let nonce: Data
    }

    static func seal(payload: Data, key: Data, nonce: Data, ad: Data) throws -> Sealed {
        let symmetric = SymmetricKey(data: key)
        let box = try AES.GCM.seal(payload,
                                   using: symmetric,
                                   nonce: AES.GCM.Nonce(data: nonce),
                                   authenticating: aad(for: ad))
        return Sealed(ciphertext: box.ciphertext, tag: box.tag, nonce: nonce)
    }

    static func open(ciphertext: Data,
                     tag: Data,
                     key: Data,
                     nonce: Data,
                     ad: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                        ciphertext: ciphertext,
                                        tag: tag)
        return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad(for: ad))
    }
}
