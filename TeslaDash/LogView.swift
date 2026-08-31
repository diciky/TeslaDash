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
