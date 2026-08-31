//
//  DashboardView.swift
//  TeslaDash
//
//  主仪表盘：车速表 + 电量 + 车身状态 + 快捷状态条。
//

import SwiftUI

struct DashboardView: View {

    @EnvironmentObject var ble: TeslaBLEManager
    @EnvironmentObject var state: VehicleState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(colors: [Color(red: 0.04, green: 0.05, blue: 0.09),
                                        Color(red: 0.07, green: 0.09, blue: 0.16)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        StatusBanner(phase: ble.phase,
                                     lastUpdate: state.lastUpdate,
                                     onTap: { ble.refreshNow() })

                        if !ble.hasKey || ble.vin.isEmpty {
                            SetupHintView()
                        }

                        SpeedGauge(speedKmh: state.speedKmh,
                                   battery: state.batteryLevel,
                                   gear: state.gear,
                                   powerKw: state.powerKw,
                                   isCharging: state.chargingState.hasPrefix("充电"))
                            .padding(.horizontal, 24)
                            .frame(maxHeight: 340)

                        DoorStrip(doors: state.doors)

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            Tile(icon: "battery.100", title: "电量",
                                 value: "\(state.batteryLevel)%", tint: .green)
                            Tile(icon: "road.lanes", title: "续航",
                                 value: dist(state.batteryRangeKm), tint: .cyan)
                            Tile(icon: "location", title: "里程",
                                 value: dist(state.odometerKm), tint: .indigo)
                            Tile(icon: "lock.fill", title: "车锁",
                                 value: state.lockState,
                                 tint: state.isLocked ? .green : .orange)
                            Tile(icon: "thermometer", title: "车内",
                                 value: temp(state.insideTempC), tint: .orange)
                            Tile(icon: "sun.max", title: "车外",
                                 value: temp(state.outsideTempC), tint: .yellow)
                            Tile(icon: "bolt.fill", title: "充电",
                                 value: state.chargingState,
                                 tint: state.chargingState.hasPrefix("充电") ? .yellow : .gray)
                            Tile(icon: "gauge.high", title: "充电功率",
                                 value: String(format: "%.1f kW", state.chargerPowerKw),
                                 tint: .pink)
                        }
                        .padding(.horizontal)

                        if state.chargingState.hasPrefix("充电") || state.chargerPowerKw > 0 {
                            ChargeCard()
                                .padding(.horizontal)
                        }

                        Spacer(minLength: 20)
                    }
                    .padding(.top, 8)
                }
            }
            .navigationTitle("TeslaDash")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { ble.refreshNow() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(ble.phase != .ready)
                }
            }
        }
        .navigationViewStyle(.stack)      // iPad 上避免分栏导致布局错乱
    }

    private func dist(_ km: Double) -> String {
        guard km > 0 else { return "—" }
        return String(format: "%.0f %@", settings.distance(km), settings.distanceLabel)
    }

    private func temp(_ c: Double?) -> String {
        guard let c = c else { return "—" }
        return String(format: "%.1f ℃", c)
    }
}

// MARK: - 顶部状态条

private struct StatusBanner: View {
    let phase: LinkPhase
    let lastUpdate: Date?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(phase.description)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let d = lastUpdate {
                    Text(Self.fmt.string(from: d))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.white.opacity(0.07))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }

    private var color: Color {
        switch phase {
        case .ready:
            return .green
        case .error:
            return .red
        case .pairing(let step):
            return step == .done ? .green : .yellow
        case .scanning, .connecting, .discovering, .authenticating:
            return .yellow
        default:
            return .gray
        }
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// MARK: - 未配置提示

private struct SetupHintView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("尚未完成配置", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.orange)
            Text("到「设置」填写 VIN，再回到车辆旁点击「开始配对」，按提示把钥匙卡放在中控台读卡器上。")
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }
}

// MARK: - 车门状态条

private struct DoorStrip: View {
    let doors: [DoorState]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(doors) { door in
                    HStack(spacing: 5) {
                        Image(systemName: door.icon)
                        Text(door.name)
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(door.isOpen ? Color.orange.opacity(0.22) : Color.white.opacity(0.06))
                    .foregroundColor(door.isOpen ? .orange : .white.opacity(0.65))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().stroke(door.isOpen ? Color.orange : Color.clear, lineWidth: 1)
                    )
                }
            }
            .padding(.horizontal)
        }
    }
}

// MARK: - 数据磁贴

private struct Tile: View {
    let icon: String
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.5))
                Text(value)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - 充电详情卡

private struct ChargeCard: View {
    @EnvironmentObject var state: VehicleState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "bolt.fill").foregroundColor(.yellow)
                Text("充电详情").font(.headline)
                Spacer()
                Text(state.isFastCharger ? "直流快充" : "交流充电")
                    .font(.caption)
                    .foregroundColor(state.isFastCharger ? .yellow : .white.opacity(0.6))
            }

            ProgressView(value: Double(state.batteryLevel), total: 100)
                .accentColor(.green)

            HStack {
                if state.chargeLimit > 0 {
                    Text("上限 \(state.chargeLimit)%").font(.caption)
                }
                Spacer()
                if state.minutesToLimit > 0 {
                    Text("约 \(state.minutesToLimit) 分钟到上限").font(.caption)
                }
            }
            .foregroundColor(.white.opacity(0.6))

            Divider().background(Color.white.opacity(0.15))

            HStack {
                detail("电压", "\(state.chargerVoltage) V")
                detail("电流", "\(state.chargerActualCurrent) A")
                detail("请求", "\(state.chargeCurrentRequest)/\(state.chargeCurrentRequestMax) A")
                detail("速率", String(format: "%.0f km/h", state.chargeRateKmh))
            }
        }
        .padding()
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func detail(_ k: String, _ v: String) -> some View {
        VStack(spacing: 2) {
            Text(k).font(.caption2).foregroundColor(.white.opacity(0.5))
            Text(v).font(.caption.monospacedDigit()).foregroundColor(.white)
        }
        .frame(maxWidth: .infinity)
    }
}

struct DashboardView_Previews: PreviewProvider {
    static var previews: some View {
        DashboardView()
            .environmentObject(TeslaBLEManager())
            .environmentObject(VehicleState(settings: AppSettings()))
            .environmentObject(AppSettings())
    }
}
