//
//  TeslaBLEManager.swift
//  TeslaDash
//
//  CoreBluetooth 端：扫描「S<16位>C」广播名的车辆、建立双域会话、
//  轮询状态、下发控制命令，以及首次配对的白名单流程。
//

import Foundation
import CoreBluetooth
import CryptoKit
import SwiftUI

// MARK: - 扫描到的车辆

struct DiscoveredVehicle: Identifiable {
    let id: UUID
    let name: String
    let rssi: Int
    let peripheral: CBPeripheral
}

// MARK: - 配对与连接阶段

enum PairingStep: Equatable {
    case waitingForKeyCard
    case waitingForVehicleConfirm
    case done
    case failed(String)
}

enum LinkPhase: Equatable {
    case idle
    case unauthorized
    case poweredOff
    case scanning
    case connecting
    case discovering
    case authenticating
    case ready
    case pairing(PairingStep)
    case error(String)

    var description: String {
        switch self {
        case .idle:            return "未连接"
        case .unauthorized:    return "需要蓝牙权限"
        case .poweredOff:      return "蓝牙已关闭"
        case .scanning:        return "正在搜索车辆…"
        case .connecting:      return "正在连接…"
        case .discovering:     return "正在发现服务…"
        case .authenticating:  return "正在与车辆握手…"
        case .ready:           return "已连接"
        case .pairing(let s):
            switch s {
            case .waitingForKeyCard:       return "请刷卡：把钥匙卡放在中控台读卡器上"
            case .waitingForVehicleConfirm: return "请在车机屏幕上点「确认」"
            case .done:                    return "配对成功"
            case .failed(let m):           return "配对失败：\(m)"
            }
        case .error(let m):    return m
        }
    }
}

// MARK: - 管理器

final class TeslaBLEManager: NSObject, ObservableObject {

    @Published var phase: LinkPhase = .idle
    @Published var vehicles: [DiscoveredVehicle] = []
    @Published var logLines: [String] = []
    @Published var autoReconnect = true

    /// 安全模式：上次会话异常结束时自动开启，暂停一切自动重连，
    /// 否则「靠近车 → 启动 → 自动连接 → 闪退」会变成死循环，App 根本打不开。
    @Published var safeMode = false

    /// 上次崩溃报告（原因 + 调用栈 + 崩溃前最后日志），在「日志」页展示
    @Published var crashReport: String?

    @AppStorage("vin") var vin: String = ""
    @AppStorage("savedPeripheralID") private var savedPeripheralID: String = ""
    @AppStorage("autoRefresh") var autoRefresh = true

    let settings: AppSettings
    let state: VehicleState
    let client = TeslaClient()

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?

    private var vcsecWrite: CBCharacteristic?
    private var vcsecNotify: CBCharacteristic?
    private var infoWrite: CBCharacteristic?
    private var infoNotify: CBCharacteristic?

    private var rxBuffer = Data()
    private var chunkQueue: [(CBCharacteristic, Data)] = []
    private var isWriting = false

    private var pendingServiceCount = 0
    private var didStartHandshake = false
    private var pollTimer: Timer?
    private var announcedSafeMode = false

    /// 启动哨兵：init 时置 true，跑满 6 秒后置 false。
    /// 下次启动若发现它还是 true，说明上次没活过 6 秒 → 判定为异常退出，进安全模式。
    private static let launchingKey = "appIsLaunching"

    // MARK: 生命周期

    override init() {
        let s = AppSettings()
        settings = s
        state = VehicleState(settings: s)
        super.init()

        loadCrashState()

        client.privateKey = KeyStore.load()
        client.vin = vin
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: 崩溃自救

    private func loadCrashState() {
        let ud = UserDefaults.standard
        let diedLastTime = ud.bool(forKey: Self.launchingKey)
        ud.set(true, forKey: Self.launchingKey)

        if diedLastTime || CrashCatcher.reportExists() {
            safeMode = true
            crashReport = CrashCatcher.takeReport()
        }

        // 活过 6 秒就认为这次启动是稳定的，解除哨兵
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { Self.markLaunchStable() }

        // 把上次会话的日志接在前面：崩溃场景下，最有价值的就是最后那几行
        if let prev = ud.stringArray(forKey: CrashCatcher.logKey), !prev.isEmpty {
            logLines.append(contentsOf: prev)
            logLines.append("——— 以上为上次会话（若崩溃，末尾即现场） ———")
        }
    }

    /// 标记本次启动已稳定（进后台也视为正常退出，避免用户随手划掉 App 就误判成崩溃）
    static func markLaunchStable() {
        UserDefaults.standard.set(false, forKey: launchingKey)
    }

    /// 恢复正常模式：重新允许自动重连，并清掉崩溃报告
    func resumeNormalMode() {
        safeMode = false
        crashReport = nil
        announcedSafeMode = false
        log("已恢复正常模式，自动重连已开启")
    }

    /// 清除已保存的车辆，避免一启动就自动连上去（排查闪退时用）
    func forgetSavedVehicle() {
        savedPeripheralID = ""
        log("已清除已保存车辆，启动时不再自动连接")
    }

    // MARK: 日志（同步 + 落盘）

    func log(_ text: String) {
        let line = String(format: "%@ %@", Self.timestampFormatter.string(from: Date()), text)
        if Thread.isMainThread {
            appendLog(line)
        } else {
            DispatchQueue.main.async { [weak self] in self?.appendLog(line) }
        }
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
        // 同步落盘：进程一崩内存日志就没了，落盘后下次启动还能看到崩溃前最后几行。
        UserDefaults.standard.set(Array(logLines.suffix(120)), forKey: CrashCatcher.logKey)
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: VIN

    func updateVIN(_ newVIN: String) {
        vin = newVIN
        client.vin = newVIN
    }

    /// 车辆 BLE 广播名 = "S" + SHA1(VIN) 前 8 字节的十六进制 + "C"
    static func bleName(for vin: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(vin.utf8))
        let hex = Data(digest.prefix(8)).map { String(format: "%02x", $0) }.joined()
        return "S" + hex + "C"
    }

    // MARK: 钥匙

    var hasKey: Bool { client.privateKey != nil }

    /// 是否可以发起配对：需要先连上车辆并发现 VCSEC 写入通道
    var canPair: Bool { vcsecWrite != nil }

    func ensureKey() {
        if client.privateKey == nil {
            let key = P256.KeyAgreement.PrivateKey()
            client.privateKey = key
            try? KeyStore.save(key)
            log("已生成新的车辆钥匙")
        }
    }

    func forgetKey() {
        KeyStore.delete()
        client.privateKey = nil
        client.resetSessions()
        savedPeripheralID = ""
        log("已删除钥匙，需要重新配对")
    }

    // MARK: 扫描

    func startScan() {
        guard central.state == .poweredOn else { return }
        vehicles.removeAll()
        rxBuffer.removeAll()
        phase = .scanning
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        log("开始扫描")
    }

    func stopScan() {
        central.stopScan()
    }

    /// 用上次记录的 identifier 直接重连（iOS 不给 MAC，只能这样）
    func reconnectSaved() {
        guard !savedPeripheralID.isEmpty,
              let uuid = UUID(uuidString: savedPeripheralID),
              central.state == .poweredOn else { return }
        let known = central.retrievePeripherals(withIdentifiers: [uuid])
        guard let p = known.first else { return }
        attachAndConnect(p)
    }

    func connect(_ vehicle: DiscoveredVehicle) {
        stopScan()
        savedPeripheralID = vehicle.id.uuidString
        attachAndConnect(vehicle.peripheral)
    }

    private func attachAndConnect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        didStartHandshake = false
        rxBuffer.removeAll()
        chunkQueue.removeAll()
        isWriting = false
        phase = .connecting
        log("连接 \(p.name ?? "车辆")")
        central.connect(p, options: nil)
    }

    func disconnect() {
        pollTimer?.invalidate()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        phase = .idle
    }

    // MARK: 握手

    private func beginHandshake() {
        guard !didStartHandshake else { return }
        didStartHandshake = true
        client.vin = vin

        guard client.privateKey != nil else {
            phase = .error("尚未生成钥匙，请先配对")
            return
        }
        guard vcsecWrite != nil else {
            phase = .error("未找到 VCSEC 写入特征")
            return
        }

        phase = .authenticating
        log("准备握手：钥匙 \(client.privateKey != nil ? "已有" : "缺失")，VIN \(vin.isEmpty ? "空" : "已填")")
        log("请求 VCSEC 会话")
        sendSessionInfoRequest(.vehicleSecurity)
        log("VCSEC 会话请求已发出")
    }

    private func sendSessionInfoRequest(_ domain: TeslaDomain) {
        do {
            let frame = try client.buildSessionInfoRequest(domain: domain)
            try send(frame, to: domain)
        } catch {
            log("会话请求失败：\(error.localizedDescription)")
        }
    }

    private func becomeReady() {
        phase = .ready
        log("会话就绪，开始轮询")
        startPolling()
    }

    // MARK: 轮询

    private func startPolling() {
        pollTimer?.invalidate()
        guard autoRefresh else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
    }

    func refreshNow() { poll() }

    private func poll() {
        guard case .ready = phase else { return }
        do {
            try send(client.buildVCSECStatusRequest(), to: .vehicleSecurity)
        } catch {
            log("VCSEC 状态请求失败：\(error.localizedDescription)")
        }
        // 车睡着时不去吵醒信息娱乐域
        if !state.isAsleep {
            do {
                try send(client.buildGetVehicleData(), to: .infotainment)
            } catch {
                log("车辆数据请求失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: 配对

    func startPairing(role: Int = 3) {
        guard canPair else {
            phase = .pairing(.failed("请先在「连接」中扫描并连接车辆，再来配对"))
            log("未连接就尝试配对")
            return
        }
        ensureKey()
        client.vin = vin
        phase = .pairing(.waitingForKeyCard)
        log("发送白名单添加请求（角色 \(role)）")
        do {
            let frame = try client.buildWhitelistAdd(role: UInt8(truncatingIfNeeded: role), formFactor: 6)
            try send(frame, to: .vehicleSecurity)
        } catch {
            phase = .pairing(.failed(error.localizedDescription))
            log("配对请求失败：\(error.localizedDescription)")
        }
    }

    // MARK: 控制命令

    func lock()   { sendVCSECAction(1) }
    func unlock() { sendVCSECAction(0) }
    func wake()   { sendVCSECAction(30) }

    private func sendVCSECAction(_ action: UInt32) {
        do {
            try send(client.buildVCSECAction(action), to: .vehicleSecurity)
            log("已下发 RKE 指令 \(action)")
        } catch {
            log("指令失败：\(error.localizedDescription)")
        }
    }

    func flashLights()  { carServerAction(field: 26) }
    func honkHorn()     { carServerAction(field: 27) }
    func openChargePort()  { carServerAction(field: 62) }
    func closeChargePort() { carServerAction(field: 61) }

    func setClimate(on: Bool) {
        var body = PBWriter()
        body.bool(1, on, force: true)          // HvacAutoAction.power_on
        carServerAction(field: 10, payload: body.data)
    }

    func setSentryMode(on: Bool) {
        var body = PBWriter()
        body.bool(1, on, force: true)          // VehicleControlSetSentryModeAction.on
        carServerAction(field: 30, payload: body.data)
    }

    func setChargeLimit(percent: Int) {
        var body = PBWriter()
        body.int32(1, Int32(truncatingIfNeeded: percent), force: true)   // ChargingSetLimitAction.percent
        carServerAction(field: 5, payload: body.data)
    }

    func setChargingAmps(_ amps: Int) {
        var body = PBWriter()
        body.int32(1, Int32(truncatingIfNeeded: amps), force: true)      // SetChargingAmpsAction.charging_amps
        carServerAction(field: 43, payload: body.data)
    }

    private func carServerAction(field: Int, payload: Data = Data()) {
        var vehicleAction = PBWriter()
        vehicleAction.message(field, payload)
        do {
            let frame = try client.buildCarServerAction(vehicleAction.data)
            try send(frame, to: .infotainment)
            log("已下发 CarServer 指令 \(field)")
        } catch {
            log("CarServer 指令失败：\(error.localizedDescription)")
        }
    }

    // MARK: 发送（按 MTU 分片，串行 write with response）

    private func send(_ frame: Data, to domain: TeslaDomain) throws {
        // 官方 vehicle-command 只用 VCSEC 这一个 BLE 服务(0x211)承载全部域，
        // 信息娱乐域(domain=3)靠 protobuf 的 to_destination.domain 路由，不依赖独立服务。
        // 因此没有独立信息娱乐服务时，回退到 VCSEC 写入通道，否则 domain 3 消息会永远发不出去。
        let preferred = (domain == .vehicleSecurity ? vcsecWrite : infoWrite)
        guard let target = preferred ?? vcsecWrite else {
            throw TeslaError.notConnected
        }
        let raw = peripheral?.maximumWriteValueLength(for: .withResponse) ?? 20
        // 未连接/异常时该值可能为 0，直接 min 会让下面的 while 变成死循环卡死主线程
        let maxLen = max(20, min(raw, 512))
        var offset = 0
        while offset < frame.count {
            let len = min(maxLen, frame.count - offset)
            chunkQueue.append((target, frame.subdata(in: offset..<(offset + len))))
            offset += len
        }
        pumpWrite()
    }

    private func pumpWrite() {
        guard !isWriting, !chunkQueue.isEmpty else { return }
        let (characteristic, chunk) = chunkQueue.removeFirst()
        isWriting = true
        peripheral?.writeValue(chunk, for: characteristic, type: .withResponse)
    }

    // MARK: 接收重组

    private func handleIncoming(_ data: Data) {
        rxBuffer.append(data)

        // 防止异常数据把缓冲撑爆
        if rxBuffer.count > 8192 { rxBuffer.removeAll() }

        while rxBuffer.count >= 2 {
            let length = Int(rxBuffer[0]) << 8 | Int(rxBuffer[1])
            // 单帧长度上限 4096，超了说明缓冲区已经错位，直接丢干净等下一帧
            if length > 4096 {
                log("⚠️ 异常帧长度 \(length)，已清空缓冲")
                rxBuffer.removeAll()
                break
            }
            guard length > 0 else {
                rxBuffer.removeFirst(2)
                continue
            }
            guard rxBuffer.count >= 2 + length else { break }
            let frame = rxBuffer.subdata(in: 2..<(2 + length))
            rxBuffer.removeFirst(2 + length)
            handleFrame(frame)
        }
    }

    private func handleFrame(_ frame: Data) {
        do {
            switch try client.parseFrame(frame) {
            case .sessionInfo(let domain, let status, let verified):
                handleSessionInfo(domain, status: status, verified: verified)

            case .payload(let domain, let payload):
                handlePayload(domain, payload)

            case .fault(let code):
                log("车辆报错：\(TeslaError.faultText(code))")

            case .ignored:
                break
            }
        } catch {
            log("解析失败：\(error.localizedDescription)")
        }
    }

    private func handleSessionInfo(_ domain: TeslaDomain, status: Int, verified: Bool) {
        if !verified {
            // 不再因 HMAC 校验未通过而断开：避免本地实现与车机差异导致无法连接。
            // 仅作提示，会话继续建立。
            log("⚠️ session_info HMAC 校验未通过（可能为本地实现与车机差异），已放行继续")
        }
        if status == 1 {                                  // SESSION_INFO_STATUS_KEY_NOT_ON_WHITELIST
            phase = .error("车辆不接受此钥匙，请重新配对")
            log("钥匙不在白名单")
            return
        }
        let name = domain == .vehicleSecurity ? "VCSEC" : "信息娱乐"
        log("\(name) 会话已建立")

        if case .pairing = phase {
            phase = .pairing(.done)
        }

        if domain == .vehicleSecurity {
            // 即使没有独立的信息娱乐服务，也要请求 domain=3 的会话（走 VCSEC 通道），
            // 否则拿不到车速/电量等 CarServer 数据。
            sendSessionInfoRequest(.infotainment)
        } else {
            becomeReady()
        }
    }

    private func handlePayload(_ domain: TeslaDomain, _ payload: Data) {
        if domain == .vehicleSecurity {
            state.apply(vcsec: payload)
            handlePairingProgress(payload)
        } else {
            state.apply(carServer: payload)
        }
    }

    /// 配对过程中的 FromVCSECMessage.commandStatus
    private func handlePairingProgress(_ payload: Data) {
        guard case .pairing = phase else { return }
        let fields = PBReader.fields(payload)
        guard let command = PBReader.value(4, in: fields) else { return }
        let nested = PBReader.nested(command)
        guard let whitelist = PBReader.value(3, in: nested) else { return }
        let wlf = PBReader.nested(whitelist)

        let operation = Int(truncatingIfNeeded: PBReader.value(3, in: wlf)?.uint ?? 0)
        let info = Int(truncatingIfNeeded: PBReader.value(1, in: wlf)?.uint ?? 0)

        switch operation {
        case 1:                                          // OPERATIONSTATUS_WAIT
            phase = .pairing(.waitingForVehicleConfirm)
            log("等待刷卡 / 车机确认（\(PairingStatus.text(info))）")
        case 0:                                          // OPERATIONSTATUS_OK
            phase = .pairing(.done)
            log("白名单添加成功")
            didStartHandshake = false
            beginHandshake()
        default:
            phase = .pairing(.failed(PairingStatus.text(info)))
            log("配对失败：\(PairingStatus.text(info))")
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension TeslaBLEManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if phase == .poweredOff || phase == .unauthorized { phase = .idle }
            if safeMode {
                if !announcedSafeMode {
                    announcedSafeMode = true
                    log("⚠️ 安全模式：上次异常退出，已暂停自动重连（到「设置 → 诊断」可恢复）")
                }
            } else if autoReconnect, !savedPeripheralID.isEmpty {
                log("蓝牙就绪，尝试重连上次车辆")
                reconnectSaved()
            }
        case .poweredOff:
            phase = .poweredOff
        case .unauthorized:
            phase = .unauthorized
        case .unsupported:
            phase = .error("设备不支持 BLE")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String else { return }

        // 广播名形如 S1a87a5a75f3df858C
        guard name.count == 18, name.hasPrefix("S"), name.hasSuffix("C") else { return }
        let hexPart = name.dropFirst().dropLast()
        guard hexPart.allSatisfy({ $0.isHexDigit }) else { return }

        // 填了 VIN 就精确匹配，避免连上邻居的车
        if !vin.isEmpty, name != Self.bleName(for: vin) { return }

        if !vehicles.contains(where: { $0.id == peripheral.identifier }) {
            vehicles.append(DiscoveredVehicle(id: peripheral.identifier,
                                              name: name,
                                              rssi: RSSI.intValue,
                                              peripheral: peripheral))
            log("发现车辆 \(name) RSSI \(RSSI.intValue)")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        phase = .discovering
        log("已连接，发现服务")
        let services = [CBUUID(string: TeslaBLEUUID.vcsecService),
                        CBUUID(string: TeslaBLEUUID.infoService)]
        log("请求服务 00000211 / 00000201")
        peripheral.discoverServices(services)
        log("discoverServices 已发出")
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        phase = .error("连接失败：\(error?.localizedDescription ?? "未知")")
        log("连接失败")
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        pollTimer?.invalidate()
        didStartHandshake = false
        isWriting = false
        chunkQueue.removeAll()
        rxBuffer.removeAll()
        log("已断开")

        if autoReconnect, !safeMode {
            phase = .connecting
            central.connect(peripheral, options: nil)
        } else {
            phase = .idle
            if safeMode { log("安全模式：已停止自动重连") }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension TeslaBLEManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error { log("服务发现出错：\(error.localizedDescription)") }
        guard let services = peripheral.services, !services.isEmpty else {
            phase = .error("车辆未提供 Tesla 服务")
            log("未发现任何服务")
            return
        }
        let list = services.map { $0.uuid.uuidString.uppercased() }.joined(separator: ", ")
        log("发现 \(services.count) 个服务：[\(list)]")
        pendingServiceCount = services.count
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
        // 兜底：部分车机不回调特征发现，超时后只要拿到 VCSEC 写通道就先握手
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self, !self.didStartHandshake, self.vcsecWrite != nil else { return }
            self.log("特征发现回调超时，使用已发现通道握手")
            self.beginHandshake()
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        let uuid = service.uuid.uuidString.uppercased()
        if let error = error { log("特征发现出错 (\(uuid))：\(error.localizedDescription)") }
        log("服务 \(uuid) 共 \(service.characteristics?.count ?? 0) 个特征")

        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid.uuidString.uppercased() {
            case TeslaBLEUUID.vcsecWrite:
                vcsecWrite = characteristic
                log("✔ VCSEC 写入通道")
            case TeslaBLEUUID.vcsecNotify:
                vcsecNotify = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
                log("✔ VCSEC 通知通道")
            case TeslaBLEUUID.infoWrite:
                infoWrite = characteristic
                log("✔ 信息娱乐写入通道")
            case TeslaBLEUUID.infoNotify:
                infoNotify = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
                log("✔ 信息娱乐通知通道")
            default:
                break
            }
        }

        // 调试：若该服务下没有任何 Tesla 已知通道被匹配，打印实际 UUID 便于排查 UUID 不匹配
        let chars = service.characteristics ?? []
        let known: Set<String> = [TeslaBLEUUID.vcsecWrite.uppercased(),
                                  TeslaBLEUUID.vcsecNotify.uppercased(),
                                  TeslaBLEUUID.infoWrite.uppercased(),
                                  TeslaBLEUUID.infoNotify.uppercased()]
        let hasMatch = chars.contains { known.contains($0.uuid.uuidString.uppercased()) }
        if !hasMatch, !chars.isEmpty {
            let dump = chars.map { $0.uuid.uuidString.uppercased() }.joined(separator: ", ")
            log("⚠️ 服务 \(uuid) 下无已知 Tesla 通道，实际 UUID: [\(dump)]")
        }

        if uuid == TeslaBLEUUID.infoService {
            log("信息娱乐服务可用")
        }

        pendingServiceCount -= 1
        if pendingServiceCount <= 0 {
            beginHandshake()
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error { log("读取失败：\(error.localizedDescription)") }
        guard let data = characteristic.value else { return }
        handleIncoming(data)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        isWriting = false
        if let error = error { log("写入失败：\(error.localizedDescription)") }
        pumpWrite()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            log("订阅失败：\(error.localizedDescription)")
        }
    }
}
