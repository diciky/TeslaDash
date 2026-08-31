//
//  VehicleState.swift
//  TeslaDash
//
//  车辆状态模型 + CarServer / VCSEC 响应解析。
//  所有字段号对齐 vehicle.proto / vcsec.proto / car_server.proto。
//

import Foundation
import SwiftUI

// MARK: - 单位设置

/// 车辆上报的速度原始单位。不同固件/地区可能不同，可在设置里切换。
enum RawSpeedUnit: Int, CaseIterable, Identifiable {
    case milesPerHour = 0
    case kilometersPerHour = 1
    case metersPerSecond = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .milesPerHour:       return "mph（默认）"
        case .kilometersPerHour:  return "km/h"
        case .metersPerSecond:    return "m/s"
        }
    }

    func toKmh(_ value: Double) -> Double {
        switch self {
        case .milesPerHour:       return value * 1.609344
        case .kilometersPerHour:  return value
        case .metersPerSecond:    return value * 3.6
        }
    }
}

enum DistanceUnit: Int, CaseIterable, Identifiable {
    case kilometers = 0
    case miles = 1

    var id: Int { rawValue }
    var label: String { self == .kilometers ? "公里" : "英里" }
}

/// 手动持久化到 UserDefaults，保证 SwiftUI 视图能即时响应单位切换
final class AppSettings: ObservableObject {
    @Published var rawSpeedUnit: Int {
        didSet { UserDefaults.standard.set(rawSpeedUnit, forKey: "rawSpeedUnit") }
    }
    @Published var distanceUnit: Int {
        didSet { UserDefaults.standard.set(distanceUnit, forKey: "distanceUnit") }
    }

    init() {
        let d = UserDefaults.standard
        rawSpeedUnit = d.object(forKey: "rawSpeedUnit") as? Int ?? RawSpeedUnit.milesPerHour.rawValue
        distanceUnit = d.object(forKey: "distanceUnit") as? Int ?? DistanceUnit.kilometers.rawValue
    }

    var speedUnit: RawSpeedUnit { RawSpeedUnit(rawValue: rawSpeedUnit) ?? .milesPerHour }
    var distUnit: DistanceUnit { DistanceUnit(rawValue: distanceUnit) ?? .kilometers }

    /// 内部一律存公里，按显示单位换算
    func distance(_ km: Double) -> Double {
        distUnit == .kilometers ? km : km / 1.609344
    }

    var distanceLabel: String { distUnit.label }
}

// MARK: - 车门

struct DoorState: Identifiable {
    let id: String
    let name: String
    var isOpen: Bool

    var icon: String {
        switch id {
        case "chargePort": return "bolt.fill"
        case "frontTrunk": return "arrow.up.to.line.compact"
        case "rearTrunk":  return "arrow.down.to.line.compact"
        default:           return "door.left.hand.open"
        }
    }
}

// MARK: - 状态模型

final class VehicleState: ObservableObject {

    // 行驶
    @Published var speedKmh: Double = 0
    @Published var gear: String = "—"
    @Published var powerKw: Int = 0
    @Published var odometerKm: Double = 0

    // 电池与充电
    @Published var batteryLevel: Int = 0
    @Published var batteryRangeKm: Double = 0
    @Published var chargeLimit: Int = 0
    @Published var chargingState: String = "未连接"
    @Published var chargerPowerKw: Double = 0
    @Published var chargerVoltage: Int = 0
    @Published var chargerActualCurrent: Int = 0
    @Published var chargeCurrentRequest: Int = 0
    @Published var chargeCurrentRequestMax: Int = 0
    @Published var minutesToLimit: Int = 0
    @Published var chargeRateKmh: Double = 0
    @Published var isFastCharger: Bool = false

    // 空调
    @Published var insideTempC: Double?
    @Published var outsideTempC: Double?
    @Published var isClimateOn: Bool = false

    // 车身
    @Published var lockState: String = "未知"
    @Published var isLocked: Bool = false
    @Published var isAsleep: Bool = false
    @Published var userPresent: Bool = false
    @Published var doors: [DoorState] = [
        DoorState(id: "frontDriver", name: "左前门", isOpen: false),
        DoorState(id: "frontPassenger", name: "右前门", isOpen: false),
        DoorState(id: "rearDriver", name: "左后门", isOpen: false),
        DoorState(id: "rearPassenger", name: "右后门", isOpen: false),
        DoorState(id: "frontTrunk", name: "前备箱", isOpen: false),
        DoorState(id: "rearTrunk", name: "后备箱", isOpen: false),
        DoorState(id: "chargePort", name: "充电口", isOpen: false)
    ]

    @Published var lastUpdate: Date?
    @Published var pairingMessage: String = ""

    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - VCSEC 解析（锁 / 门窗 / 睡眠 / 在场）

    /// FromVCSECMessage
    func apply(vcsec data: Data) {
        let fields = PBReader.fields(data)

        if let status = PBReader.value(1, in: fields) {           // vehicleStatus
            applyVehicleStatus(PBReader.nested(status))
        }
        if let command = PBReader.value(4, in: fields) {          // commandStatus
            applyCommandStatus(PBReader.nested(command))
        }
    }

    private func applyVehicleStatus(_ f: [(field: Int, value: PBValue)]) {
        // closureStatuses (1)
        let closures = PBReader.nested(PBReader.value(1, in: f))
        let isOpen: (Int) -> Bool = { field in
            guard let v = PBReader.value(field, in: closures)?.uint else { return false }
            // CLOSURESTATE_OPEN = 1, AJAR = 2
            return v == 1 || v == 2
        }
        setDoor("frontDriver", isOpen(1))
        setDoor("frontPassenger", isOpen(2))
        setDoor("rearDriver", isOpen(3))
        setDoor("rearPassenger", isOpen(4))
        setDoor("rearTrunk", isOpen(5))
        setDoor("frontTrunk", isOpen(6))
        setDoor("chargePort", isOpen(7))

        // vehicleLockState (2)：0 解锁 / 1 锁定 / 2 内部锁定 / 3 选择性解锁
        let lockRaw = Int(truncatingIfNeeded: PBReader.value(2, in: f)?.uint ?? 0)
        isLocked = (lockRaw == 1 || lockRaw == 2)
        lockState = ["已解锁", "已锁定", "内部锁定", "选择性解锁"].indiciesSafe(lockRaw)

        // vehicleSleepStatus (3)
        isAsleep = (PBReader.value(3, in: f)?.uint == 2)

        // userPresence (4)
        userPresent = (PBReader.value(4, in: f)?.uint == 2)

        lastUpdate = Date()
    }

    private func applyCommandStatus(_ f: [(field: Int, value: PBValue)]) {
        // 配对流程：WhitelistOperation_status (3)
        if let wl = PBReader.value(3, in: f) {
            let nested = PBReader.nested(wl)
            let info = Int(truncatingIfNeeded: PBReader.value(1, in: nested)?.uint ?? 0)
            let opStatus = Int(truncatingIfNeeded: PBReader.value(3, in: nested)?.uint ?? 0)
            pairingMessage = "\(PairingStatus.text(info))（状态 \(opStatus)）"
        }
    }

    private func setDoor(_ id: String, _ open: Bool) {
        guard let i = doors.firstIndex(where: { $0.id == id }) else { return }
        doors[i].isOpen = open
    }

    // MARK: - CarServer 解析（车速 / 电量 / 空调）

    /// CarServer.Response
    func apply(carServer data: Data) {
        let fields = PBReader.fields(data)
        guard let vd = PBReader.value(2, in: fields) else { return }   // vehicleData
        applyVehicleData(PBReader.nested(vd))
    }

    private func applyVehicleData(_ f: [(field: Int, value: PBValue)]) {
        if let charge = PBReader.value(3, in: f) { applyChargeState(PBReader.nested(charge)) }
        if let climate = PBReader.value(4, in: f) { applyClimateState(PBReader.nested(climate)) }
        if let drive = PBReader.value(5, in: f) { applyDriveState(PBReader.nested(drive)) }
        lastUpdate = Date()
    }

    private func applyDriveState(_ f: [(field: Int, value: PBValue)]) {
        // ShiftState (1)：Invalid=1 / P=2 / R=3 / N=4 / D=5 / SNA=6
        let shift = PBReader.nested(PBReader.value(1, in: f)).first?.field ?? 0
        gear = ["—", "无效", "P", "R", "N", "D", "—"].indiciesSafe(shift)

        // 速度：优先浮点（106），回退整数（102）
        let rawSpeed: Double
        if let sf = PBReader.float(PBReader.value(106, in: f)) {
            rawSpeed = Double(sf)
        } else if let v = PBReader.value(102, in: f)?.uint {
            rawSpeed = Double(v)
        } else {
            rawSpeed = 0
        }
        speedKmh = max(0, settings.speedUnit.toKmh(rawSpeed))

        // power (103) 单位 kW
        if let p = PBReader.value(103, in: f) {
            powerKw = Int(truncatingIfNeeded: p.uint)
        }

        // 里程：百分之一英里
        if let o = PBReader.value(105, in: f) {
            let miles = Double(Int(truncatingIfNeeded: o.uint)) / 100.0
            odometerKm = miles * 1.609344
        }
    }

    private func applyChargeState(_ f: [(field: Int, value: PBValue)]) {
        // ChargingState (1)：Unknown=1 / Disconnected=2 / NoPower=3 / Starting=4
        //                    Charging=5 / Complete=6 / Stopped=7 / Calibrating=8
        let stateField = PBReader.nested(PBReader.value(1, in: f)).first?.field ?? 1
        chargingState = ["—", "未知", "未连接", "无电源", "启动中",
                         "充电中", "已完成", "已停止", "校准中"].indiciesSafe(stateField)

        batteryLevel = intOr(114, in: f)
        chargeLimit = intOr(104, in: f)
        minutesToLimit = intOr(142, in: f)
        chargerVoltage = intOr(119, in: f)
        chargerActualCurrent = intOr(121, in: f)
        chargeCurrentRequest = intOr(137, in: f)
        chargeCurrentRequestMax = intOr(138, in: f)
        isFastCharger = PBReader.value(110, in: f)?.bool ?? false

        // 续航：源值英里 → 公里
        let rangeMiles = Double(PBReader.float(PBReader.value(111, in: f)) ?? 0)
        batteryRangeKm = rangeMiles * 1.609344

        // 充电功率 kW
        chargerPowerKw = Double(intOr(122, in: f))

        // 充电速率：优先浮点 mph（156），回退整数（126）
        if let rate = PBReader.float(PBReader.value(156, in: f)) {
            chargeRateKmh = Double(rate) * 1.609344
        } else {
            chargeRateKmh = Double(intOr(126, in: f)) * 1.609344
        }
    }

    private func applyClimateState(_ f: [(field: Int, value: PBValue)]) {
        insideTempC = PBReader.float(PBReader.value(101, in: f)).map { Double($0) }
        outsideTempC = PBReader.float(PBReader.value(102, in: f)).map { Double($0) }
        isClimateOn = PBReader.value(110, in: f)?.bool ?? false
    }

    private func intOr(_ field: Int, in fields: [(field: Int, value: PBValue)]) -> Int {
        guard let v = PBReader.value(field, in: fields)?.uint else { return 0 }
        return Int(truncatingIfNeeded: v)
    }
}

// MARK: - 配对状态文案

enum PairingStatus {
    static func text(_ code: Int) -> String {
        switch code {
        case 0:  return "成功"
        case 1:  return "未记录的错误"
        case 2:  return "无权移除自身"
        case 3:  return "遥控钥匙槽位已满"
        case 4:  return "白名单已满"
        case 5:  return "无添加权限"
        case 6:  return "公钥无效"
        case 12: return "公钥不在白名单"
        case 13: return "该钥匙已在白名单中"
        case 14: return "需在中控读卡器上刷卡"
        case 24: return "车机端已拒绝"
        case 25: return "等待刷卡超时"
        case 26: return "等待车机确认超时"
        case 27: return "代客模式禁止此操作"
        case 28: return "已取消"
        default: return "代码 \(code)"
        }
    }
}

// MARK: - 小工具

private extension Array where Element == String {
    func indiciesSafe(_ index: Int) -> Element {
        guard index >= 0, index < count else { return "—" }
        return self[index]
    }
}
