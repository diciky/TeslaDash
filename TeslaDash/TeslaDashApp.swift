//
//  TeslaDashApp.swift
//  TeslaDash
//
//  应用入口。全局共享一个 BLE 管理器，避免重复创建 CBCentralManager。
//

import SwiftUI

@main
struct TeslaDashApp: App {

    @StateObject private var ble = TeslaBLEManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(ble)
                .environmentObject(ble.state)
                .environmentObject(ble.settings)
        }
    }
}

// MARK: - 根视图（iOS 15 兼容：用 TabView + NavigationView，不用 NavigationStack）

struct RootView: View {

    @EnvironmentObject var ble: TeslaBLEManager

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("仪表盘", systemImage: "speedometer") }

            ControlsView()
                .tabItem { Label("控制", systemImage: "switch.2") }

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }

            LogView()
                .tabItem { Label("日志", systemImage: "text.alignleft") }
        }
        .preferredColorScheme(.dark)
    }
}
