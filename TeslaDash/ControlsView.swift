//
//  ControlsView.swift
//  TeslaDash
//
//  快捷控制：锁/解锁/唤醒、闪灯/鸣笛、充电口、空调、哨兵、充电上限与电流。
//  iOS 15 兼容：用 Picker(selection:)... .pickerStyle(SegmentedPickerStyle()) 而非新 API。
//

import SwiftUI

struct ControlsView: View {

    @EnvironmentObject var ble: TeslaBLEManager
    @EnvironmentObject var state: VehicleState

    @State private var climateOn = false
    @State private var sentryOn = false
    @State private var chargeLimit = 80
    @State private var chargingAmps = 16

    private var enabled: Bool { ble.phase == .ready }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 18) {
                    if !enabled {
                        HStack {
                            Image(systemName: "exclamationmark.lock")
                            Text("车辆未连接，请先在「设置」完成配对与连接")
                                .font(.caption)
                        }
                        .foregroundColor(.orange)
                        .padding()
                        .background(Color.orange.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                    }

                    Group {
                        Text("车身").sectionTitle()
                        HStack(spacing: 12) {
                            ActionButton("解锁", "lock.open.fill", .green) { ble.unlock() }
                            ActionButton("上锁", "lock.fill", .orange) { ble.lock() }
                            ActionButton("唤醒", "zzz", .blue) { ble.wake() }
                        }
                    }

                    Group {
                        Text("灯光与声音").sectionTitle()
                        HStack(spacing: 12) {
                            ActionButton("闪灯", "lightbulb.fill", .yellow) { ble.flashLights() }
                            ActionButton("鸣笛", "speaker.wave.2.fill", .red) { ble.honkHorn() }
                        }
                    }

                    Group {
                        Text("充电口").sectionTitle()
                        HStack(spacing: 12) {
                            ActionButton("打开", "bolt.circle", .green) { ble.openChargePort() }
                            ActionButton("关闭", "bolt.slash.circle", .gray) { ble.closeChargePort() }
                        }
                    }

                    Group {
                        Text("空调").sectionTitle()
                        Toggle("开启空调", isOn: $climateOn)
                            .onChange(of: climateOn) { newValue in ble.setClimate(on: newValue) }
                            .disabled(!enabled)
                            .padding(.horizontal)
                            .toggleStyle(SwitchToggleStyle(tint: .cyan))
                    }

                    Group {
                        Text("哨兵模式").sectionTitle()
                        Toggle("开启哨兵", isOn: $sentryOn)
                            .onChange(of: sentryOn) { newValue in ble.setSentryMode(on: newValue) }
                            .disabled(!enabled)
                            .padding(.horizontal)
                            .toggleStyle(SwitchToggleStyle(tint: .red))
                    }

                    Group {
                        Text("充电上限").sectionTitle()
                        VStack(spacing: 6) {
                            Text("\(chargeLimit)%")
                                .font(.system(size: 24, weight: .heavy, design: .rounded))
                                .monospacedDigit()
                            Slider(value: Binding(get: { Double(chargeLimit) },
                                                 set: { chargeLimit = lround($0); ble.setChargeLimit(percent: chargeLimit) }),
                                   in: 50...100, step: 1)
                                .accentColor(.green)
                                .disabled(!enabled)
                        }
                        .padding(.horizontal)
                    }

                    Group {
                        Text("充电电流").sectionTitle()
                        HStack {
                            Button { if chargingAmps > 1 { chargingAmps -= 1; ble.setChargingAmps(chargingAmps) } }
                            label: { Image(systemName: "minus.circle.fill").font(.title) }
                            Text("\(chargingAmps) A").monospacedDigit()
                                .frame(minWidth: 60)
                            Button { if chargingAmps < 32 { chargingAmps += 1; ble.setChargingAmps(chargingAmps) } }
                            label: { Image(systemName: "plus.circle.fill").font(.title) }
                            Spacer()
                            Text("请求/最大：\(state.chargeCurrentRequest)/\(state.chargeCurrentRequestMax) A")
                                .font(.caption).foregroundColor(.white.opacity(0.5))
                        }
                        .foregroundColor(enabled ? .blue : .gray)
                        .padding(.horizontal)
                    }

                    Spacer(minLength: 20)
                }
                .padding(.vertical)
            }
            .navigationTitle("控制")
        }
        .navigationViewStyle(.stack)
        .onAppear {
            chargeLimit = state.chargeLimit > 0 ? state.chargeLimit : 80
            climateOn = state.isClimateOn
        }
    }
}

// MARK: - 通用按钮

private struct ActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    init(_ title: String, _ icon: String, _ color: Color, _ action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.color = color; self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 24))
                Text(title).font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(color.opacity(0.18))
            .foregroundColor(color)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.4), lineWidth: 1))
        }
    }
}

private extension Text {
    func sectionTitle() -> some View {
        self.font(.caption.uppercased())
            .foregroundColor(.white.opacity(0.45))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
    }
}

struct ControlsView_Previews: PreviewProvider {
    static var previews: some View {
        ControlsView()
            .environmentObject(TeslaBLEManager())
            .environmentObject(VehicleState(settings: AppSettings()))
    }
}
