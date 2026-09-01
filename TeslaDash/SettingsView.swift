//
//  SettingsView.swift
//  TeslaDash
//
//  配对、VIN、单位与钥匙管理。
//

import SwiftUI
import UIKit

struct SettingsView: View {

    @EnvironmentObject var ble: TeslaBLEManager
    @EnvironmentObject var settings: AppSettings

    @State private var vinInput: String = ""
    @State private var pairingRole = 3
    @State private var vinSaved = false

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("车辆")) {
                    HStack {
                        Text("VIN")
                        Spacer()
                        TextField("17 位车架号", text: $vinInput)
                            .multilineTextAlignment(.trailing)
                            .autocapitalization(.allCharacters)
                            .disableAutocorrection(true)
                            .onSubmit { applyVin() }
                    }
                    Button {
                        haptic()
                        applyVin()
                    } label: {
                        HStack {
                            Text("保存 VIN")
                            Spacer()
                            if vinSaved {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            }
                        }
                    }
                    .disabled(vinInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Section(header: Text("配对")) {
                    if ble.hasKey {
                        HStack {
                            Image(systemName: "key.fill").foregroundColor(.green)
                            Text("钥匙已存在（无需重新配对）")
                        }
                    } else {
                        HStack {
                            Image(systemName: "key").foregroundColor(.orange)
                            Text("尚未生成钥匙")
                        }
                    }

                    Picker("角色", selection: $pairingRole) {
                        Text("车主 (2)").tag(2)
                        Text("驾驶员 (3)").tag(3)
                        Text("充电管理员 (6)").tag(6)
                    }
                    .pickerStyle(SegmentedPickerStyle())

                    Button {
                        haptic()
                        ble.ensureKey()
                        ble.startPairing(role: pairingRole)
                    } label: {
                        Label("开始配对", systemImage: "plus.circle.fill")
                    }
                    .disabled(ble.vin.isEmpty || !ble.canPair)

                    if case .pairing(let step) = ble.phase {
                        HStack {
                            Image(systemName: "ellipsis.circle.fill").foregroundColor(.yellow)
                            Text(step.description(for: step))
                        }
                    }

                    if ble.hasKey {
                        Button(role: .destructive) {
                            ble.forgetKey()
                        } label: {
                            Label("删除钥匙并重置", systemImage: "trash.fill")
                        }
                    }
                }

                Section(header: Text("显示单位")) {
                    Picker("速度原始单位", selection: $settings.rawSpeedUnit) {
                        ForEach(RawSpeedUnit.allCases) { u in
                            Text(u.label).tag(u.rawValue)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())

                    Picker("里程/续航", selection: $settings.distanceUnit) {
                        ForEach(DistanceUnit.allCases) { u in
                            Text(u.label).tag(u.rawValue)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                }

                Section(header: Text("连接")) {
                    Toggle("自动刷新数据（10s）", isOn: $ble.autoRefresh)
                        .toggleStyle(SwitchToggleStyle(tint: .blue))
                    Toggle("断线自动重连", isOn: $ble.autoReconnect)
                        .toggleStyle(SwitchToggleStyle(tint: .blue))

                    Button {
                        haptic()
                        switch ble.phase {
                        case .idle, .error:
                            ble.reconnectSaved()
                        default:
                            break
                        }
                        ble.startScan()
                    } label: {
                        Label("扫描车辆", systemImage: "antenna.radiowaves.left.and.right")
                    }

                    Button(role: .destructive) {
                        haptic()
                        ble.disconnect()
                    } label: {
                        Label("断开连接", systemImage: "xmark.octagon.fill")
                    }
                }

                // 扫描到的车辆：点一下即连接。
                // 之前扫描结果只写进日志、界面没有任何入口，导致车扫得到却永远连不上，
                // 进而 vcsecWrite 始终为空、"开始配对"一直灰着。
                if !ble.vehicles.isEmpty {
                    Section(header: Text("发现的车辆（点击连接）")) {
                        ForEach(ble.vehicles) { v in
                            Button {
                                haptic()
                                ble.connect(v)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "car.fill")
                                        .foregroundColor(.green)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(v.name)
                                            .font(.system(size: 13, design: .monospaced))
                                            .foregroundColor(.primary)
                                        Text("信号 \(v.rssi) dBm")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Text("连接")
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }

                Section(header: Text("关于")) {
                    HStack {
                        Text("协议")
                        Spacer()
                        Text("Tesla BLE (VCSEC + CarServer)")
                            .foregroundColor(.white.opacity(0.5))
                            .font(.footnote)
                    }
                    HStack {
                        Text("最低系统")
                        Spacer()
                        Text("iOS 15.0").foregroundColor(.white.opacity(0.5)).font(.footnote)
                    }
                    HStack {
                        Text("构建")
                        Spacer()
                        Text("2026-08-31").foregroundColor(.white.opacity(0.5)).font(.footnote)
                    }
                    Link("特斯拉 BLE 协议说明",
                         destination: URL(string: "https://github.com/teslamotors/vehicle-command")!)
                        .font(.footnote)
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle("设置")
            .onAppear { vinInput = ble.vin }
        }
        .navigationViewStyle(.stack)
    }

    private func applyVin() {
        let v = vinInput.trimmingCharacters(in: .whitespaces).uppercased()
        ble.updateVIN(v)
        vinInput = v
        withAnimation { vinSaved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { vinSaved = false }
        }
    }

    /// 轻触感反馈：让每个按钮点击都有明确的手感回应，解决"不知道点没点上"的问题
    private func haptic() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

private extension PairingStep {
    func description(for step: PairingStep) -> String {
        switch step {
        case .waitingForKeyCard:        return "请把钥匙卡放在中控台读卡器上"
        case .waitingForVehicleConfirm: return "请在车机屏幕上点「确认」"
        case .done:                     return "配对成功"
        case .failed(let m):            return "配对失败：\(m)"
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(TeslaBLEManager())
            .environmentObject(AppSettings())
    }
}
