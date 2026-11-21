import SwiftUI

struct ContentView: View {
    @ObservedObject var ble: BLEManager
    @State private var tab = 0
    @State private var showDetail = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = ble.errorText {
                errorBanner(error)
            }
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
        .onChange(of: ble.pumpServiceFound) { found in
            if found { tab = 2 }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Equil 探测版")
                    .font(.system(size: 19, weight: .semibold))
                Spacer()
                if ble.connected != nil {
                    Button("断开") { ble.disconnect() }
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }
            }
            Text(ble.statusText)
                .font(.system(size: 12))
                .foregroundColor(ble.pumpServiceFound ? .green : (ble.connected != nil ? .orange : .gray))
            Text("0.1 只做扫描与帧抓取，暂不能控泵")
                .font(.system(size: 11))
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(Color(red: 1, green: 0.75, blue: 0.3))
            Spacer()
            Button("关闭") { ble.clearError() }
                .font(.system(size: 12))
                .foregroundColor(.gray)
        }
        .padding(12)
        .background(Color(red: 0.22, green: 0.13, blue: 0.08))
    }

    private var scanTab: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button(ble.scanning ? "停止扫描" : "开始扫描") {
                    if ble.scanning { ble.stopScan() } else { ble.startScan() }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.22, green: 0.82, blue: 0.64))

                if ble.errorText != nil {
                    Button("重试连接") { ble.retry() }
                        .buttonStyle(.bordered)
                }
            }
            .padding(.top, 8)

            Text("贴泵息屏时不广播：先按一下泵上的按键唤醒，再扫描。若泵正连着 AAPS/原厂 App，iOS 会连不上，需要先断开那台手机。")
                .font(.system(size: 12))
                .foregroundColor(.gray)
                .padding(.horizontal, 16)

            List(ble.devices) { d in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.name)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.white)
                        Text(d.peripheral.identifier.uuidString)
                            .font(.system(size: 10))
                            .foregroundColor(.gray)
                        if d.likelyPump {
                            Text("疑似贴泵（广播含 F000/FFE0）")
                                .font(.system(size: 10))
                                .foregroundColor(.green)
                        }
                    }
                    Spacer()
                    Text("\(d.rssi)dB")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                    Button("连接") { ble.connect(d) }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.22, green: 0.82, blue: 0.64))
                        .font(.system(size: 13))
                }
                .contentShape(Rectangle())
                .onTapGesture { ble.connect(d) }
            }
            .listStyle(.plain)
            .refreshable { ble.startScan() }
        }
    }

    private var statusTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                group("链路") {
                    row("连接状态", ble.statusText)
                    row("设备名", ble.connectedName.isEmpty ? "-" : ble.connectedName)
                    row("服务数", "\(ble.serviceNames.count)")
                    row("贴泵服务", ble.pumpServiceFound ? "已找到" : "未找到")
                }
                group("已发现服务") {
                    if ble.serviceNames.isEmpty {
                        Text("连接后自动枚举").font(.system(size: 12)).foregroundColor(.gray)
                    } else {
                        ForEach(ble.serviceNames.indices, id: \.self) { i in
                            Text(ble.serviceNames[i])
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.white)
                        }
                    }
                }
                group("控制") {
                    Text("大剂量 / 临时基础率 / 暂停 / 恢复 / 基础率编辑")
                        .font(.system(size: 13))
                        .foregroundColor(.gray)
                    Text("这些要等 0.2 把厂商帧协议用 Swift 重写后才能开放。先用「帧」页把真实帧抓下来。")
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
                if ble.frames.isEmpty {
                    Text(ble.pumpServiceFound
                         ? "已连上贴泵，但还没收到通知帧。按一下泵上的按键或等它心跳推送。"
                         : "还没有收到帧，先把贴泵连上。")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                }
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
            Text(value).font(.system(size: 13, weight: .medium))
        }
    }
}
