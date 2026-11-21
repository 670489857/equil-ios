import SwiftUI

struct ContentView: View {
    @ObservedObject var ble: BLEManager
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            TabView(selection: $tab) {
                scanTab.tag(0)
                statusTab.tag(1)
                frameTab.tag(2)
                logTab.tag(3)
            }
            .tabViewStyle(.automatic)
        }
        .background(Color(red: 0.04, green: 0.07, blue: 0.12))
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Equil 探测版")
                .font(.system(size: 20, weight: .semibold))
            Text(ble.connectedName.isEmpty ? (ble.poweredOn ? "未连接" : "蓝牙不可用") : "已连接 \(ble.connectedName)")
                .font(.system(size: 12))
                .foregroundColor(ble.connectedName.isEmpty ? .gray : .green)
            Text("0.1 只做扫描与帧抓取，暂不能控泵")
                .font(.system(size: 11))
                .foregroundColor(.orange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var scanTab: some View {
        VStack(spacing: 12) {
            Button(ble.scanning ? "停止扫描" : "开始扫描") {
                if ble.scanning { ble.stopScan() } else { ble.startScan() }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.22, green: 0.82, blue: 0.64))

            Text("标“疑似贴泵”的广播包含 F000/FFE0 服务 UUID。贴泵息屏时可能不广播，先按泵上的按键唤醒。")
                .font(.system(size: 12))
                .foregroundColor(.gray)
                .padding(.horizontal, 16)

            List(ble.devices) { d in
                Button {
                    ble.connect(d)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.name).foregroundColor(.white)
                            Text(d.peripheral.identifier.uuidString)
                                .font(.system(size: 10))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        if d.likelyPump {
                            Text("疑似贴泵").font(.system(size: 11)).foregroundColor(.green)
                        }
                        Text("\(d.rssi)dB").font(.system(size: 11)).foregroundColor(.gray)
                    }
                }
            }
            .listStyle(.plain)

            if ble.connected != nil {
                Button("断开连接") { ble.disconnect() }
                    .foregroundColor(.red)
            }
        }
    }

    private var statusTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                group("状态") {
                    row("运行模式", "待接入")
                    row("当前基础率", "待接入")
                    row("电量", "待接入")
                    row("药量", "待接入")
                }
                group("控制") {
                    Text("大剂量 / 临时基础率 / 暂停 / 恢复 / 基础率编辑")
                        .font(.system(size: 13))
                        .foregroundColor(.gray)
                    Text("iOS 版需要重写厂商协议（Android SDK 与 .so 无法在 iOS 上运行），本轮先交付链路探测，协议接入在 0.2。")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                }
            }
            .padding(16)
        }
    }

    private var frameTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("最新帧 \(ble.lastFrameHex.isEmpty ? "-" : ble.lastFrameHex)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.green)
                Text("已发现特征 \(ble.characteristics.count) 个")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                Divider()
                ForEach(ble.frames.indices, id: \.self) { i in
                    Text(ble.frames[i])
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private var logTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(ble.logs.indices, id: \.self) { i in
                    Text(ble.logs[i])
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13)).foregroundColor(.gray)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.08, green: 0.11, blue: 0.17))
        .cornerRadius(14)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 13)).foregroundColor(.gray)
            Spacer()
            Text(value).font(.system(size: 14, weight: .medium))
        }
    }
}
