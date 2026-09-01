//
//  LogView.swift
//  TeslaDash
//
//  实时蓝牙/协议日志，便于排查握手与配对问题。
//

import SwiftUI
import UIKit

struct LogView: View {

    @EnvironmentObject var ble: TeslaBLEManager

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {

                if let report = ble.crashReport {
                    CrashReportCard(report: report) {
                        UIPasteboard.general.string = report
                    } dismiss: {
                        ble.resumeNormalMode()
                    }
                }

                if ble.logLines.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "text.alignleft")
                            .font(.system(size: 40))
                            .foregroundColor(.white.opacity(0.3))
                        Text("暂无日志。连接车辆后这里会显示握手、配对与轮询过程。")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.5))
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(ble.logLines.enumerated()), id: \.offset) { i, line in
                                    Text(line)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.green.opacity(0.85))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(i)
                                }
                            }
                            .padding(10)
                        }
                        .onChange(of: ble.logLines.count) { _ in
                            withAnimation { proxy.scrollTo(ble.logLines.count - 1, anchor: .bottom) }
                        }
                    }
                }

                HStack {
                    Button { UIPasteboard.general.string = ble.logLines.joined(separator: "\n") } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                    Spacer()
                    Button { ble.logLines.removeAll() } label: {
                        Label("清空", systemImage: "trash")
                    }
                }
                .buttonStyle(.bordered)
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .navigationTitle("日志")
        }
        .navigationViewStyle(.stack)
    }
}

struct LogView_Previews: PreviewProvider {
    static var previews: some View {
        LogView().environmentObject(TeslaBLEManager())
    }
}

// MARK: - 崩溃报告卡
// 上次崩溃的原因 + 调用栈 + 崩溃前最后日志，直接摆在日志页最上面，
// 便于把内容复制出来定位问题。

private struct CrashReportCard: View {

    let report: String
    let copy: () -> Void
    let dismiss: () -> Void

    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundColor(.red)
                Text("上次运行发生崩溃")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.red)
                Spacer()
                Button(expanded ? "收起" : "展开") { expanded.toggle() }
                    .font(.caption)
            }

            if expanded {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(report)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.red.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)

                HStack {
                    Button { copy() } label: { Label("复制报告", systemImage: "doc.on.doc") }
                    Spacer()
                    Button { dismiss() } label: { Label("恢复正常模式", systemImage: "checkmark.circle") }
                }
                .font(.caption)
            }
        }
        .padding(12)
        .background(Color.red.opacity(0.10))
        .overlay(
            Rectangle().fill(Color.red.opacity(0.5)).frame(height: 1),
            alignment: .bottom
        )
    }
}
