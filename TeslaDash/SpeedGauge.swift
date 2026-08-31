//
//  SpeedGauge.swift
//  TeslaDash
//
//  纯 Path 手绘的仪表盘（不用 iOS 16 的 Gauge，保证 iOS 15 可用）。
//  外圈 = 车速，内圈 = 电量，中央显示档位与数值。
//

import SwiftUI

struct SpeedGauge: View {

    var speedKmh: Double
    var maxSpeed: Double = 240
    var battery: Int = 0
    var gear: String = "—"
    var powerKw: Int = 0
    var isCharging: Bool = false

    private let startDeg: Double = 135
    private let sweepDeg: Double = 270

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let outer = size / 2 - 14
            let inner = outer - 24

            ZStack {
                // 刻度
                Ticks(center: center,
                      radius: outer - 2,
                      startDeg: startDeg,
                      sweepDeg: sweepDeg,
                      count: 28)
                .stroke(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

                // 速度底环
                arc(center: center, radius: outer, from: startDeg, to: startDeg + sweepDeg)
                    .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 12, lineCap: .round))

                // 速度进度环
                arc(center: center, radius: outer,
                    from: startDeg, to: startDeg + sweepDeg * fraction)
                .stroke(speedGradient, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .shadow(color: .cyan.opacity(0.5), radius: 8)

                // 电量底环
                arc(center: center, radius: inner, from: startDeg, to: startDeg + sweepDeg)
                    .stroke(Color.white.opacity(0.10), style: StrokeStyle(lineWidth: 6, lineCap: .round))

                // 电量进度环
                arc(center: center, radius: inner,
                    from: startDeg, to: startDeg + sweepDeg * batteryFraction)
                .stroke(batteryColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))

                // 中央读数
                VStack(spacing: 2) {
                    Text(gear)
                        .font(.system(size: size * 0.10, weight: .bold, design: .rounded))
                        .foregroundColor(gear == "D" ? .green : (gear == "R" ? .orange : .white))

                    Text("\(lround(speedKmh))")
                        .font(.system(size: size * 0.30, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.white)

                    Text("km/h")
                        .font(.system(size: size * 0.062, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))

                    HStack(spacing: 4) {
                        Image(systemName: isCharging ? "bolt.fill" : "battery.100percent")
                            .foregroundColor(isCharging ? .yellow : .green)
                        Text("\(battery)%")
                            .monospacedDigit()
                    }
                    .font(.system(size: size * 0.072, weight: .semibold))
                    .foregroundColor(.white)

                    Text(powerKw == 0 ? "" : String(format: "%+d kW", powerKw))
                        .font(.system(size: size * 0.058, weight: .medium, design: .rounded))
                        .foregroundColor(powerKw > 0 ? .orange : .teal)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // MARK: 计算

    private var fraction: Double {
        guard maxSpeed > 0 else { return 0 }
        return min(1, max(0, speedKmh / maxSpeed))
    }

    private var batteryFraction: Double {
        min(1, max(0, Double(battery) / 100.0))
    }

    private var batteryColor: Color {
        if isCharging { return .yellow }
        if battery <= 10 { return .red }
        if battery <= 20 { return .orange }
        return .green
    }

    private var speedGradient: AngularGradient {
        AngularGradient(gradient: Gradient(colors: [.cyan, .blue, .purple, .pink]),
                        center: .center,
                        startAngle: .degrees(startDeg),
                        endAngle: .degrees(startDeg + sweepDeg))
    }

    private func arc(center: CGPoint, radius: CGFloat, from: Double, to: Double) -> Path {
        var p = Path()
        // 保证零长度弧不绘制，避免出现一个整圆
        guard to - from > 0.5 else {
            p.addArc(center: center, radius: radius,
                     startAngle: .degrees(from), endAngle: .degrees(from + 0.5),
                     clockwise: false)
            return p
        }
        p.addArc(center: center, radius: radius,
                 startAngle: .degrees(from), endAngle: .degrees(to),
                 clockwise: false)
        return p
    }
}

// MARK: - 刻度

private struct Ticks: Shape {
    let center: CGPoint
    let radius: CGFloat
    let startDeg: Double
    let sweepDeg: Double
    let count: Int

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let long = radius - 10
        for i in 0...count {
            let deg = startDeg + sweepDeg * Double(i) / Double(count)
            let rad = deg * .pi / 180
            let isMajor = i % 4 == 0
            let r1 = radius - (isMajor ? 12 : 6)
            let r0 = isMajor ? long - 4 : long
            p.move(to: CGPoint(x: center.x + r0 * cos(rad), y: center.y + r0 * sin(rad)))
            p.addLine(to: CGPoint(x: center.x + r1 * cos(rad), y: center.y + r1 * sin(rad)))
        }
        return p
    }
}
