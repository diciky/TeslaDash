//
//  SettingsView.swift
//  TeslaDash
//
//  配对、VIN、单位与钥匙管理。
//

import SwiftUI

struct SettingsView: View {

    @EnvironmentObject var ble: TeslaBLEManager
    @EnvironmentObject var settings: AppSettings

    @State private var vinInput: String = ""
    @State private var pairingRole = 3

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
                    Button("保存 VIN") { applyVin() }
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
                        ble.ensureKey()
                        ble.startPairing(role: pairingRole)
                    } label: {
                        Label("开始配对", systemImage: "plus.circle.fill")
                    }
                    .disabled(ble.vin.isEmpty)

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
                        ble.disconnect()
                    } label: {
                        Label("断开连接", systemImage: "xmark.octagon.fill")
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
