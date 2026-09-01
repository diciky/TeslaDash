//
//  TeslaDashApp.swift
//  TeslaDash
//
//  应用入口。全局共享一个 BLE 管理器，避免重复创建 CBCentralManager。
//

import SwiftUI
import UIKit

// MARK: - 崩溃捕获
// 连接阶段闪退、又拿不到设备崩溃日志时，靠这个把原因和调用栈持久化到 UserDefaults，
// 下次启动自动打印到「日志」页，变"盲猜"为"精准定位"。

enum CrashCatcher {

    static let key = "lastCrashReport"

    /// 与 TeslaBLEManager 共用的日志落盘键：崩溃报告里直接附上最后若干行日志，
    /// 这样不用等下次启动，一眼就能看到崩溃发生在哪一步。
    static let logKey = "persistedLog"

    static func install() {
        NSSetUncaughtExceptionHandler { ex in
            let report = """
            [崩溃] NSException: \(ex.name.rawValue)
            原因: \(ex.reason ?? "未知")
            调用栈:
            \(ex.callStackSymbols.prefix(25).joined(separator: "\n"))
            """
            CrashCatcher.save(report)
        }

        // 捕获常见致命信号（Swift 数组越界 / 强制解包 nil / ObjC 异常最终多走 SIGABRT）
        let handler: @convention(c) (Int32) -> Void = { sig in
            let report = """
            [崩溃] 信号 \(CrashCatcher.signalName(sig))
            调用栈:
            \(Thread.callStackSymbols.prefix(25).joined(separator: "\n"))
            """
            CrashCatcher.save(report)
            signal(sig, SIG_DFL)   // 恢复默认处理，让系统生成正常崩溃报告
            raise(sig)
        }
        signal(SIGABRT, handler)
        signal(SIGSEGV, handler)
        signal(SIGILL, handler)
        signal(SIGBUS, handler)
        signal(SIGFPE, handler)
    }

    private static func save(_ report: String) {
        let tail = (UserDefaults.standard.stringArray(forKey: logKey) ?? []).suffix(30)
        var full = report
        if !tail.isEmpty {
            full += "\n\n崩溃前最后日志:\n" + tail.joined(separator: "\n")
        }
        UserDefaults.standard.set(full, forKey: key)
        UserDefaults.standard.synchronize()
    }

    static func signalName(_ s: Int32) -> String {
        switch s {
        case SIGABRT: return "SIGABRT（断言/异常：数组越界、强制解包 nil、ObjC 异常等）"
        case SIGSEGV: return "SIGSEGV（非法内存访问）"
        case SIGILL:  return "SIGILL（非法指令）"
        case SIGBUS:  return "SIGBUS（总线错误）"
        case SIGFPE:  return "SIGFPE（算术错误，如除零）"
        default:      return "信号 \(s)"
        }
    }

    /// 上次是否留下了崩溃报告（不清除，供启动时的安全模式判断使用）
    static func reportExists() -> Bool {
        guard let r = UserDefaults.standard.string(forKey: key) else { return false }
        return !r.isEmpty
    }

    /// 取出上次崩溃报告并清除（只读一次）
    static func takeReport() -> String? {
        guard let r = UserDefaults.standard.string(forKey: key), !r.isEmpty else { return nil }
        UserDefaults.standard.removeObject(forKey: key)
        return r
    }
}

@main
struct TeslaDashApp: App {

    @StateObject private var ble = TeslaBLEManager()

    init() {
        CrashCatcher.install()
    }

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
    @Environment(\.scenePhase) private var scenePhase

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
        .onChange(of: scenePhase) { p in
            // 正常切后台：解除崩溃哨兵，下次启动不再误判为异常退出
            if p != .active { TeslaBLEManager.markLaunchStable() }
        }
    }
}
