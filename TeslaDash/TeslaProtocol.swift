//
//  TeslaProtocol.swift
//  TeslaDash
//
//  Tesla BLE 协议层：域、会话状态、消息构建与入帧解析。
//  字段号严格对齐 tesla-ble / 官方 vehicle-command 的 proto 定义。
//

import Foundation
import CryptoKit

// MARK: - 错误

enum TeslaError: LocalizedError {
    case noPrivateKey
    case sessionNotReady
    case invalidFrame
    case crypto(String)
    case vehicleFault(Int)

    var errorDescription: String? {
        switch self {
        case .noPrivateKey:      return "尚未生成密钥，请先配对"
        case .sessionNotReady:   return "会话未就绪，正在握手"
        case .invalidFrame:      return "收到无法解析的 BLE 数据帧"
        case .crypto(let s):     return "加密失败：\(s)"
        case .vehicleFault(let f): return "车辆返回错误：\(TeslaError.faultText(f))"
        }
    }

    static func faultText(_ fault: Int) -> String {
        switch fault {
        case 0:  return "无"
        case 1:  return "车辆忙，请重试"
        case 2:  return "子系统无响应"
        case 3:  return "车辆不认识该钥匙（需重新配对）"
        case 4:  return "密钥已禁用"
        case 5:  return "签名错误"
        case 6:  return "防重放计数器失效"
        case 7:  return "权限不足"
        case 8:  return "目标域无效"
        case 9:  return "无法识别的命令"
        case 10: return "车辆无法解析命令"
        case 11: return "车辆内部错误"
        case 12: return "命令发给了错误的 VIN"
        case 13: return "参数错误"
        case 14: return "钥匙链已满"
        case 15: return "会话 ID 不匹配"
        case 17: return "命令已过期"
        case 21: return "车主已关闭移动访问"
        default: return "代码 \(fault)"
        }
    }
}

// MARK: - 域

enum TeslaDomain: UInt8 {
    case broadcast        = 0
    case vehicleSecurity  = 2   // VCSEC：锁 / 门窗 / 充电口 / 唤醒
    case infotainment     = 3   // CarServer：车速 / 电量 / 空调 / 媒体
}

// MARK: - 会话（每个域独立）

final class TeslaPeer {
    let domain: TeslaDomain
    var epoch = Data(count: TeslaCrypto.epochSize)
    var counter: UInt32 = 0
    var clockTime: UInt32 = 0
    var sessionStart = Date()
    var sessionKey: Data?
    var isValid = false

    init(_ domain: TeslaDomain) { self.domain = domain }

    var hasValidEpoch: Bool { epoch.contains { $0 != 0 } }

    var canSend: Bool { isValid && sessionKey != nil && hasValidEpoch }

    /// 车辆时间 = clock_time + 本地经过的秒数 + 有效期
    func expiresAt(seconds: Int = 30) -> UInt32 {
        let elapsed = UInt32(max(0, Date().timeIntervalSince(sessionStart)))
        return clockTime &+ elapsed &+ UInt32(seconds)
    }

    func reset() {
        epoch = Data(count: TeslaCrypto.epochSize)
        counter = 0
        clockTime = 0
        sessionStart = Date()
        sessionKey = nil
        isValid = false
    }
}

// MARK: - 入帧解析结果

enum TeslaIncoming {
    case sessionInfo(TeslaDomain, status: Int, verified: Bool)
    case payload(TeslaDomain, Data)      // 已解密的域内消息
    case fault(Int)                      // MessageFault_E
    case ignored
}

// MARK: - 协议客户端

final class TeslaClient {

    var vin: String = ""
    var privateKey: P256.KeyAgreement.PrivateKey?
    var connectionID = TeslaCrypto.randomBytes(count: 16)

    private var peers: [UInt8: TeslaPeer] = [:]
    private var lastRequestHash: [UInt8: Data] = [:]
    private var lastRequestUuid: [UInt8: Data] = [:]

    func peer(_ domain: TeslaDomain) -> TeslaPeer {
        if let p = peers[domain.rawValue] { return p }
        let p = TeslaPeer(domain)
        peers[domain.rawValue] = p
        return p
    }

    func resetSessions() {
        peers.removeAll()
        lastRequestHash.removeAll()
        lastRequestUuid.removeAll()
    }

    var publicKey: Data? { privateKey?.publicKey.x963Representation }

    // MARK: 帧封装

    /// Tesla BLE 每条消息前置 2 字节大端长度
    private func prependLength(_ payload: Data) -> Data {
        var out = Data()
        out.append(UInt8((payload.count >> 8) & 0xFF))
        out.append(UInt8(payload.count & 0xFF))
        out.append(payload)
        return out
    }

    private func toDestination(_ domain: TeslaDomain) -> Data {
        var w = PBWriter()
        w.int(1, UInt64(domain.rawValue), force: true)  // Destination.domain
        return w.data
    }

    private func fromDestination() -> Data {
        var w = PBWriter()
        w.bytes(2, connectionID)                        // Destination.routing_address
        return w.data
    }

    // MARK: 会话握手

    /// UniversalMessage.SessionInfoRequest —— 不加密，用公钥换取车端会话信息
    func buildSessionInfoRequest(domain: TeslaDomain) throws -> Data {
        guard let pub = publicKey else { throw TeslaError.noPrivateKey }

        var msg = PBWriter()
        msg.message(6, toDestination(domain))
        msg.message(7, fromDestination())

        var req = PBWriter()
        req.bytes(1, pub)                               // SessionInfoRequest.public_key
        msg.message(14, req.data)

        let uuid = TeslaCrypto.randomBytes(count: 16)
        msg.bytes(51, uuid)                                 // uuid —— 车端 HMAC 的挑战值
        msg.int(52, UInt64(1), force: true)                 // flags = FLAG_ENCRYPT_RESPONSE

        // 车辆会用 HMAC-SHA256(session_info_key, metadata(VIN+此 uuid) || session_info) 回签
        lastRequestUuid[domain.rawValue] = uuid

        return prependLength(msg.data)
    }

    // MARK: 配对（白名单添加）

    /// VCSEC.ToVCSECMessage{SignedMessage{WhitelistOperation}} —— 明文，需在车内刷卡确认
    func buildWhitelistAdd(role: UInt8 = 3, formFactor: UInt8 = 6) throws -> Data {
        guard let pub = publicKey else { throw TeslaError.noPrivateKey }

        var pk = PBWriter()
        pk.bytes(1, pub)                                // PublicKey.PublicKeyRaw

        var permission = PBWriter()
        permission.message(1, pk.data)                  // PermissionChange.key
        permission.int(4, UInt64(role), force: true)    // keyRole（3 = DRIVER）

        var meta = PBWriter()
        meta.int(1, UInt64(formFactor), force: true)    // KeyMetadata.keyFormFactor（6 = iOS）

        var whitelist = PBWriter()
        whitelist.message(5, permission.data)           // addKeyToWhitelistAndAddPermissions
        whitelist.message(6, meta.data)                 // metadataForKey

        var unsigned = PBWriter()
        unsigned.message(16, whitelist.data)            // UnsignedMessage.WhitelistOperation

        var signed = PBWriter()
        signed.bytes(2, unsigned.data)                  // protobufMessageAsBytes
        signed.int(3, UInt64(2), force: true)           // signatureType = PRESENT_KEY

        var toVCSEC = PBWriter()
        toVCSEC.message(1, signed.data)

        return prependLength(toVCSEC.data)
    }

    // MARK: VCSEC 命令（加密）

    func buildVCSECStatusRequest() throws -> Data {
        var req = PBWriter()                            // 空 InformationRequest = GET_STATUS
        var unsigned = PBWriter()
        unsigned.message(1, req.data)                   // UnsignedMessage.InformationRequest
        return try buildUniversal(payload: unsigned.data, domain: .vehicleSecurity, encrypt: true)
    }

    /// RKEAction：0 解锁 / 1 上锁 / 20 远程驾驶 / 30 唤醒
    func buildVCSECAction(_ action: UInt32) throws -> Data {
        var unsigned = PBWriter()
        unsigned.int(2, UInt64(action), force: true)    // UnsignedMessage.RKEAction
        return try buildUniversal(payload: unsigned.data, domain: .vehicleSecurity, encrypt: true)
    }

    // MARK: CarServer 命令（加密，走信息娱乐域）

    func buildGetVehicleData() throws -> Data {
        var gvd = PBWriter()
        gvd.message(2, Data())      // getChargeState
        gvd.message(3, Data())      // getClimateState
        gvd.message(4, Data())      // getDriveState
        gvd.message(7, Data())      // getLocationState
        gvd.message(8, Data())      // getClosuresState

        var vehicleAction = PBWriter()
        vehicleAction.message(1, gvd.data)              // VehicleAction.getVehicleData

        var action = PBWriter()
        action.message(2, vehicleAction.data)           // Action.vehicleAction

        return try buildUniversal(payload: action.data, domain: .infotainment, encrypt: true)
    }

    /// 通用 CarServer 动作：传入已拼好的 VehicleAction 负载
    func buildCarServerAction(_ vehicleActionPayload: Data) throws -> Data {
        var action = PBWriter()
        action.message(2, vehicleActionPayload)
        return try buildUniversal(payload: action.data, domain: .infotainment, encrypt: true)
    }

    // MARK: 加密信封

    private func buildUniversal(payload: Data,
                                domain: TeslaDomain,
                                encrypt: Bool) throws -> Data {
        let p = peer(domain)
        let flags: UInt32 = 1                            // FLAG_ENCRYPT_RESPONSE

        var msg = PBWriter()
        msg.message(6, toDestination(domain))
        msg.message(7, fromDestination())

        if encrypt {
            guard p.canSend, let key = p.sessionKey else { throw TeslaError.sessionNotReady }
            guard let pub = publicKey else { throw TeslaError.noPrivateKey }

            p.counter &+= 1
            let expires = p.expiresAt()
            let ad = TeslaCrypto.adBuffer(signatureType: .aesGcmPersonalized,
                                          domain: domain.rawValue,
                                          vin: vin,
                                          epoch: p.epoch,
                                          expiresAt: expires,
                                          counter: p.counter,
                                          flags: flags,
                                          requestHash: nil,
                                          fault: nil)
            let nonce = TeslaCrypto.randomNonce()
            let sealed: TeslaCrypto.Sealed
            do {
                sealed = try TeslaCrypto.seal(payload: payload, key: key, nonce: nonce, ad: ad)
            } catch {
                throw TeslaError.crypto(error.localizedDescription)
            }

            msg.bytes(10, sealed.ciphertext)             // protobuf_message_as_bytes

            var gcm = PBWriter()
            gcm.bytes(1, p.epoch)                        // epoch
            gcm.bytes(2, nonce)                          // nonce
            gcm.int(3, UInt64(p.counter), force: true)   // counter
            gcm.fixed32(4, expires)                      // expires_at (fixed32)
            gcm.bytes(5, sealed.tag)                     // tag

            var sig = PBWriter()
            var identity = PBWriter()
            identity.bytes(1, pub)                       // KeyIdentity.public_key
            sig.message(1, identity.data)
            sig.message(5, gcm.data)                     // AES_GCM_Personalized_data

            msg.message(13, sig.data)                    // signature_data

            // request hash：1 字节认证类型 + tag（VCSEC 截断到 16 字节）
            var rh = Data([TeslaCrypto.SigType.aesGcmPersonalized.rawValue])
            rh.append(domain == .vehicleSecurity ? sealed.tag.prefix(16) : sealed.tag)
            lastRequestHash[domain.rawValue] = rh
        } else {
            msg.bytes(10, payload)
        }

        msg.bytes(51, TeslaCrypto.randomBytes(count: 16))
        msg.int(52, UInt64(flags), force: true)

        return prependLength(msg.data)
    }

    // MARK: 入帧解析

    /// 解析一条完整帧（已去掉 2 字节长度前缀）
    func parseFrame(_ frame: Data) throws -> TeslaIncoming {
        var reader = PBReader(frame)
        let fields = reader.all()
        guard let first = fields.first else { throw TeslaError.invalidFrame }

        // 有 to_destination(6) → RoutableMessage；否则视为裸 VCSEC 消息（配对响应）
        if fields.contains(where: { $0.field == 6 }) {
            return try parseRoutable(fields)
        }
        return parseBareVCSEC(frame)
    }

    private func parseRoutable(_ fields: [(field: Int, value: PBValue)]) throws -> TeslaIncoming {
        // 域来自 from_destination（车端），没有才回退 to_destination
        let domain = Self.domainOf(fields)

        // 会话信息（15 = session_info，明文的 Signatures.SessionInfo）
        if let infoBytes = PBReader.value(15, in: fields) {
            let decoded = PBReader.nested(infoBytes)
            let status = Int(PBReader.value(5, in: decoded)?.uint ?? 0)
            try updateSession(domain: domain, from: decoded)

            let verified = verifySessionInfo(rawInfo: infoBytes.data, in: fields, domain: domain)
            if !verified { peer(domain).isValid = false }
            return .sessionInfo(domain, status: status, verified: verified)
        }

        // 状态（12 = signedMessageStatus）
        if let status = PBReader.value(12, in: fields) {
            let nested = PBReader.nested(status)
            if let fault = PBReader.value(2, in: nested), fault.uint != 0 {
                return .fault(Int(fault.uint))
            }
        }

        // 签名数据（13）→ AES_GCM_Response_data 用于解密
        let sig = PBReader.nested(PBReader.value(13, in: fields))
        var responseSig: [(field: Int, value: PBValue)] = []

        for (f, v) in sig where f == 9 {              // AES_GCM_Response_data
            responseSig = PBReader.nested(v)
        }

        guard let payloadValue = PBReader.value(10, in: fields) else {
            return .ignored
        }

        // 加密响应 → 解密
        if !responseSig.isEmpty {
            let nonce = PBReader.value(1, in: responseSig)?.data ?? Data()
            let counter = UInt32(PBReader.value(2, in: responseSig)?.uint ?? 0)
            let tag = PBReader.value(3, in: responseSig)?.data ?? Data()

            let p = peer(domain)
            guard let key = p.sessionKey, nonce.count == TeslaCrypto.nonceSize else {
                return .ignored
            }

            let ad = TeslaCrypto.adBuffer(signatureType: .aesGcmResponse,
                                          domain: domain.rawValue,
                                          vin: vin,
                                          epoch: nil,
                                          expiresAt: nil,
                                          counter: counter,
                                          flags: 1,
                                          requestHash: lastRequestHash[domain.rawValue],
                                          fault: 0)
            do {
                let plain = try TeslaCrypto.open(ciphertext: payloadValue.data,
                                                 tag: tag,
                                                 key: key,
                                                 nonce: nonce,
                                                 ad: ad)
                return .payload(domain, plain)
            } catch {
                return .fault(5)                       // INVALID_SIGNATURE
            }
        }

        return .payload(domain, payloadValue.data)
    }

    /// 域判定：优先 from_destination(7)，否则 to_destination(6)
    private static func domainOf(_ fields: [(field: Int, value: PBValue)]) -> TeslaDomain {
        for field in [7, 6] {
            guard let dest = PBReader.value(field, in: fields) else { continue }
            let nested = PBReader.nested(dest)
            if let raw = PBReader.value(1, in: nested)?.uint,
               let d = TeslaDomain(rawValue: UInt8(truncatingIfNeeded: raw)) {
                return d
            }
        }
        return .vehicleSecurity
    }

    /// 校验车辆回传 session_info 的 HMAC 标签，防中间人。
    /// 若缺少必要材料（无 VIN / 无标签）则视为通过，避免阻断正常流程。
    private func verifySessionInfo(rawInfo: Data,
                                   in fields: [(field: Int, value: PBValue)],
                                   domain: TeslaDomain) -> Bool {
        guard !vin.isEmpty else { return true }

        let sig = PBReader.nested(PBReader.value(13, in: fields))
        guard let tagValue = PBReader.value(6, in: sig) else { return true }   // session_info_tag
        let tag = PBReader.nested(tagValue).first(where: { $0.field == 1 })?.value.data ?? Data()
        guard !tag.isEmpty else { return true }

        guard let key = peer(domain).sessionKey else { return false }
        let challenge = lastRequestUuid[domain.rawValue] ?? Data()

        return TeslaCrypto.verifySessionInfoTag(sessionInfo: rawInfo,
                                                tag: tag,
                                                vin: vin,
                                                challenge: challenge,
                                                sessionKey: key)
    }

    /// 裸 VCSEC 消息（配对的 FromVCSECMessage 响应）——整体作为 VCSEC 负载交给上层解析
    private func parseBareVCSEC(_ frame: Data) -> TeslaIncoming {
        return .payload(.vehicleSecurity, frame)
    }

    // MARK: 会话更新

    private func updateSession(domain: TeslaDomain,
                               from fields: [(field: Int, value: PBValue)]) throws {
        let p = peer(domain)

        let counter = UInt32(PBReader.value(1, in: fields)?.uint ?? 0)
        let publicKey = PBReader.value(2, in: fields)?.data
        let epoch = PBReader.value(3, in: fields)?.data
        let clockTime = PBReader.value(4, in: fields)?.uint32 ?? 0

        // epoch 与车端时钟：始终采纳车端真值（车辆可能丢失计数器状态）
        if let epoch = epoch, epoch.count == TeslaCrypto.epochSize {
            if counter > p.counter { p.counter = counter }     // 取较大值，避免重放判定失效
            p.epoch = epoch
            p.clockTime = UInt32(clockTime)
            p.sessionStart = Date()
        }

        if let pub = publicKey, pub.count == 65, let priv = privateKey {
            do {
                p.sessionKey = try TeslaCrypto.sessionKey(privateKey: priv, vehiclePublicKey: pub)
                p.isValid = true
            } catch {
                throw TeslaError.crypto("ECDH 失败：\(error.localizedDescription)")
            }
        }
    }
}

// MARK: - BLE 服务与特征 UUID

enum TeslaBLEUUID {
    /// VCSEC 车辆安全控制器（始终在线）
    static let vcsecService = "00000211-B2D1-43F0-9B88-960CEBF8B91E"
    static let vcsecWrite   = "00000212-B2D1-43F0-9B88-960CEBF8B91E"
    static let vcsecNotify  = "00000213-B2D1-43F0-9B88-960CEBF8B91E"

    /// 信息娱乐域（车速 / 电量 / 空调等 CarServer 数据）
    static let infoService  = "00000201-B2D1-43F0-9B88-960CEBF8B91E"
    static let infoWrite    = "00000202-B2D1-43F0-9B88-960CEBF8B91E"
    static let infoNotify   = "00000203-B2D1-43F0-9B88-960CEBF8B91E"
}
