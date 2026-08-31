//
//  Protobuf.swift
//  TeslaDash
//
//  极简 Protocol Buffers 编解码器（零第三方依赖）
//  仅实现 Tesla BLE 协议用到的 wire type：0(varint) / 1(fixed64) / 2(bytes) / 5(fixed32)
//

import Foundation

// MARK: - 解码值

enum PBValue {
    case varint(UInt64)
    case fixed64(UInt64)
    case bytes(Data)
    case fixed32(UInt32)

    var uint: UInt64 {
        if case .varint(let v) = self { return v }
        return 0
    }

    /// fixed32 值（用于 protobuf fixed32 字段，如 SessionInfo.clock_time）
    var uint32: UInt32 {
        if case .fixed32(let v) = self { return v }
        return 0
    }

    var int: Int { Int(truncatingIfNeeded: uint) }

    var bool: Bool { uint != 0 }

    var data: Data {
        if case .bytes(let d) = self { return d }
        return Data()
    }
}

// MARK: - 编码器

struct PBWriter {
    private(set) var data = Data()

    mutating func putVarInt(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(truncatingIfNeeded: v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(truncatingIfNeeded: v))
    }

    mutating func tag(_ field: Int, _ wire: Int) {
        putVarInt(UInt64(field << 3 | wire))
    }

    /// proto3 标量语义：默认省略 0。车辆对加密元数据校验严格，必要时 force=true 强制写出。
    mutating func int(_ field: Int, _ value: UInt64, force: Bool = false) {
        if value == 0 && !force { return }
        tag(field, 0)
        putVarInt(value)
    }

    /// 有符号 32 位：负数按 protobuf 规范补成 64 位再编码
    mutating func int32(_ field: Int, _ value: Int32, force: Bool = false) {
        int(field, UInt64(bitPattern: Int64(value)), force: force)
    }

    mutating func bool(_ field: Int, _ value: Bool, force: Bool = false) {
        int(field, value ? 1 : 0, force: force)
    }

    /// wire type 2：bytes / string / 嵌套 message 通用
    mutating func bytes(_ field: Int, _ value: Data) {
        tag(field, 2)
        putVarInt(UInt64(value.count))
        data.append(value)
    }

    mutating func string(_ field: Int, _ value: String) {
        bytes(field, Data(value.utf8))
    }

    mutating func message(_ field: Int, _ value: Data) {
        bytes(field, value)
    }

    mutating func fixed32(_ field: Int, _ value: UInt32) {
        tag(field, 5)
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    mutating func fixed64(_ field: Int, _ value: UInt64) {
        tag(field, 1)
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }
}

// MARK: - 解码器

struct PBReader {
    private let data: Data
    private var index: Int = 0

    init(_ data: Data) {
        self.data = data
    }

    mutating func readVarInt() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.count {
            let b = data[index]
            index += 1
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    mutating func next() -> (field: Int, value: PBValue)? {
        guard let key = readVarInt() else { return nil }
        let field = Int(key >> 3)
        let wire = Int(key & 0x07)

        switch wire {
        case 0:
            guard let v = readVarInt() else { return nil }
            return (field, .varint(v))

        case 1:
            guard index + 8 <= data.count else { return nil }
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(data[index + i]) << UInt64(8 * i) }
            index += 8
            return (field, .fixed64(v))

        case 2:
            guard let len = readVarInt(), index + Int(len) <= data.count else { return nil }
            let start = index
            index += Int(len)
            return (field, .bytes(data.subdata(in: start..<index)))

        case 5:
            guard index + 4 <= data.count else { return nil }
            var v: UInt32 = 0
            for i in 0..<4 { v |= UInt32(data[index + i]) << UInt32(8 * i) }
            index += 4
            return (field, .fixed32(v))

        default:
            return nil
        }
    }

    /// 把一条 message 解成「字段号 → 值」的列表（嵌套 message 以 bytes 形式保留，可继续递归）
    mutating func all() -> [(field: Int, value: PBValue)] {
        var out: [(field: Int, value: PBValue)] = []
        while let f = next() { out.append(f) }
        return out
    }

    /// 一次性解出全部字段（省去调用方声明 var）
    static func fields(_ data: Data) -> [(field: Int, value: PBValue)] {
        var r = PBReader(data)
        return r.all()
    }

    /// 便捷取字段
    static func value(_ field: Int, in fields: [(field: Int, value: PBValue)]) -> PBValue? {
        fields.first(where: { $0.field == field })?.value
    }

    /// 递归进入嵌套 message
    static func nested(_ value: PBValue?) -> [(field: Int, value: PBValue)] {
        guard let v = value, case .bytes(let d) = v else { return [] }
        var r = PBReader(d)
        return r.all()
    }

    /// float（fixed32 位模式）
    static func float(_ value: PBValue?) -> Float? {
        guard let v = value, case .fixed32(let bits) = v else { return nil }
        return Float(bitPattern: bits)
    }
}
