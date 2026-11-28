import SwiftUI

struct ContentView: View {
    @ObservedObject var ble: BLEManager
    @State private var tab = 0

    @State private var password = UserDefaults.standard.string(forKey: "equil_pwd") ?? "0000"
    @State private var bolusText = "2.0"
    @State private var tempPercent = "120"
    @State private var tempHours = "1"
    @State private var rawHex = ""
    @State private var sofText = "7E"
    @State private var escText = "7D"
    @State private var confirm: PendingAction? = nil
    @State private var patchDays = UserDefaults.standard.integer(forKey: "equil_patch_days") == 0 ? 3 : UserDefaults.standard.integer(forKey: "equil_patch_days")
    @State private var wizardStep = 0

    enum PendingAction: Identifiable {
        case bolus(Double)
        case stopBolus
        case rewind
        case prime
        case stopPump
        case cancelTemp
        var id: Int {
            switch self {
            case .bolus: return 1
            case .stopBolus: return 2
            case .rewind: return 3
            case .prime: return 4
            case .stopPump: return 5
            case .cancelTemp: return 6
            }
        }
        var title: String {
            switch self {
            case .bolus(let u): return "确认大剂量 \(String(format: "%.2f", u)) U"
            case .stopBolus: return "确认停止大剂量"
            case .rewind: return "确认退药 3 U（会推回储药器）"
            case .prime: return "确认排气 2 U"
            case .stopPump: return "确认停止输注（模式=停止）"
            case .cancelTemp: return "确认取消临时基础率"
            }
        }
        var detail: String { "命令会立即通过蓝牙下发给贴泵，请确认贴泵已贴好。" }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = ble.errorText { errorBanner(error) }
            TabView(selection: $tab) {
                deviceTab.tag(0)
                controlTab.tag(1)
                debugTab.tag(2)
                logTab.tag(3)
            }
        }
        .background(Color(red: 0.04, green: 0.07, blue: 0.12))
        .preferredColorScheme(.dark)
        .alert(item: $confirm) { action in
            Alert(title: Text(action.title), message: Text(action.detail),
                  primaryButton: .destructive(Text("下发")) { perform(action) },
                  secondaryButton: .cancel(Text("取消")))
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("科研泵 3.1")
                    .font(.system(size: 17, weight: .semibold))
                Text("v3.1")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                Spacer()
                if ble.connected != nil {
                    Button("断开") { ble.disconnect() }
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }
            }
            HStack(spacing: 6) {
                Circle().fill(ble.writableReady ? Color.green : (ble.connected != nil ? Color.orange : Color.gray))
                    .frame(width: 8, height: 8)
                Text(ble.statusText).font(.system(size: 12)).foregroundColor(.gray)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color(red: 0.07, green: 0.1, blue: 0.16))
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text).font(.system(size: 12)).foregroundColor(.orange)
            Spacer()
            Button("×") { ble.clearError() }.foregroundColor(.gray)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - 设备

    private var deviceTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button(ble.scanning ? "扫描中…" : "扫描贴泵") {
                        if ble.scanning { ble.stopScan() } else { ble.startScan() }
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                    if ble.connected == nil, !ble.devices.isEmpty {
                        Button("重试连接") { ble.retry() }.font(.system(size: 12))
                    }
                }
                Toggle("断线自动重连（5 秒）", isOn: $ble.autoReconnect)
                    .font(.system(size: 12))

                ForEach(ble.devices) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.system(size: 14, weight: .medium))
                            Text("\(item.rssi) dBm \(item.likelyPump ? "· 疑似贴泵" : "")")
                                .font(.system(size: 11)).foregroundColor(.gray)
                        }
                        Spacer()
                        Button("连接") { ble.connect(item) }
                            .buttonStyle(.bordered)
                            .font(.system(size: 12))
                    }
                }
                if ble.devices.isEmpty {
                    Text("没扫到设备：先确认贴泵已唤醒（贴泵上电/按键），且原手机 App 已断开。")
                        .font(.system(size: 12)).foregroundColor(.gray)
                }
                if !ble.serviceNames.isEmpty {
                    sectionCard("服务与特征") {
                        ForEach(ble.serviceNames, id: \.self) { s in
                            Text(s).font(.system(size: 10, design: .monospaced)).foregroundColor(.gray)
                        }
                        if !ble.writableReady {
                            Text("未找到可写特征，命令无法下发").font(.system(size: 11)).foregroundColor(.orange)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: - 控制

    private var controlTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sectionCard("贴泵状态") {
                    HStack {
                        statusItem("模式", modeText)
                        statusItem("写入", ble.writableReady ? "就绪" : "未就绪")
                        statusItem("收发", "\(ble.txCount)/\(ble.rxCount)")
                    }
                    Text(patchCountdown).font(.system(size: 12)).foregroundColor(.gray)
                }

                sectionCard("基础命令") {
                    HStack(spacing: 8) {
                        cmdButton("查询设备") { ble.send(EquilCommands.queryDevice(address: ble.bindAddress)) }
                        cmdButton("读模式") { ble.send(EquilCommands.queryMode(address: ble.bindAddress)) }
                    }
                    HStack(spacing: 8) {
                        cmdButton("暂停") { ble.send(EquilCommands.setMode(address: ble.bindAddress, mode: 0)) }
                        cmdButton("恢复") { ble.send(EquilCommands.setMode(address: ble.bindAddress, mode: 1)) }
                        cmdButton("停止") { confirm = .stopPump }
                    }
                }

                sectionCard("大剂量") {
                    HStack {
                        TextField("单位 U", text: $bolusText)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                        Button("立即输注") {
                            if let u = Double(bolusText), u > 0 { confirm = .bolus(u) }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("停止") { confirm = .stopBolus }
                            .buttonStyle(.bordered)
                            .foregroundColor(.orange)
                    }
                    Text("按 25 mU 取整下发；单次上限见设置。").font(.system(size: 11)).foregroundColor(.gray)
                }

                sectionCard("临时基础率（百分比）") {
                    HStack {
                        TextField("百分比 %", text: $tempPercent)
                            .keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                        TextField("时长 h", text: $tempHours)
                            .keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                        Button("下发") {
                            if let p = Int(tempPercent), let h = Double(tempHours), p > 0, h > 0 {
                                ble.send(EquilCommands.setTempPercent(address: ble.bindAddress, percent: p, intervalSeconds: Int(h * 3600)))
                            }
                        }.buttonStyle(.borderedProminent)
                        Button("取消") { confirm = .cancelTemp }.buttonStyle(.bordered)
                    }
                }

                sectionCard("换片 / 维护") {
                    HStack(spacing: 8) {
                        cmdButton("退药 3U") { confirm = .rewind }
                        cmdButton("排气 2U") { confirm = .prime }
                    }
                    Text("换片顺序：停止 → 退药 → 取旧片 → 装新片 → 排气 → 恢复 → 记录。").font(.system(size: 11)).foregroundColor(.gray)
                    HStack {
                        Button(wizardStep == 0 ? "开始换片向导" : "换片步骤 \(wizardStep)/5") {
                            wizardStep = wizardStep >= 5 ? 0 : wizardStep + 1
                            runWizardStep(wizardStep - 1)
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                    }
                    Button("记录已换片（重置 3 天倒计时）") {
                        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "equil_patch_at")
                        patchDays = 3
                    }
                    .font(.system(size: 12))
                }

                sectionCard("绑定与设置") {
                    HStack {
                        Text("泵密码").font(.system(size: 12))
                        TextField("0000", text: $password)
                            .keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                        Button("绑定") {
                            let pwd = Array(password.utf8)
                            ble.send(EquilCommands.bindPassword(address: ble.bindAddress, password: pwd))
                            UserDefaults.standard.set(password, forKey: "equil_pwd")
                        }.buttonStyle(.bordered)
                    }
                    Text("密码是泵上设定的 4 位数字；AAPS 首次绑定会把密码写入泵，之后连泵只做比对。")
                        .font(.system(size: 11)).foregroundColor(.gray)
                }
            }
            .padding(16)
        }
    }

    private var modeText: String {
        switch ble.pumpMode {
        case 0: return "暂停"
        case 1: return "运行"
        case 2: return "停止"
        default: return "未知"
        }
    }

    private var patchCountdown: String {
        let at = UserDefaults.standard.double(forKey: "equil_patch_at")
        guard at > 0 else { return "未记录换片，到期时间未知" }
        let left = at + Double(patchDays) * 86400 - Date().timeIntervalSince1970
        let hours = Int(left / 3600)
        return left > 0 ? "贴片剩余约 \(hours) 小时" : "贴片已超期 \(abs(hours)) 小时，请更换"
    }

    // MARK: - 调试

    private var debugTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sectionCard("帧参数") {
                    HStack {
                        Text("SOF").font(.system(size: 12))
                        TextField("7E", text: $sofText).textFieldStyle(.roundedBorder).frame(width: 60)
                        Text("ESC").font(.system(size: 12))
                        TextField("7D", text: $escText).textFieldStyle(.roundedBorder).frame(width: 60)
                        Button("应用") {
                            if let s = UInt8(sofText, radix: 16) { EquilProtocol.shared.codec.sof = s }
                            if let e = UInt8(escText, radix: 16) { EquilProtocol.shared.codec.esc = e }
                            ble.log("帧参数改为 SOF=\(sofText) ESC=\(escText)")
                        }.buttonStyle(.bordered)
                    }
                }
                sectionCard("发原始 HEX") {
                    TextEditor(text: $rawHex)
                        .frame(height: 90)
                        .font(.system(size: 12, design: .monospaced))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
                    HStack {
                        Button("发送") { ble.sendRaw(hex: rawHex) }.buttonStyle(.borderedProminent)
                        Button("填入查询设备帧") {
                            let frame = EquilProtocol.shared.frame(for: EquilCommands.queryDevice(address: ble.bindAddress))
                            rawHex = frame.map { String(format: "%02X", $0) }.joined(separator: " ")
                        }.buttonStyle(.bordered).font(.system(size: 12))
                    }
                }
                sectionCard("最近回帧（原始）") {
                    ForEach(ble.frames.prefix(10), id: \.self) { f in
                        Text(f).font(.system(size: 10, design: .monospaced)).foregroundColor(.gray)
                    }
                    if ble.frames.isEmpty {
                        Text("还没有收到数据").font(.system(size: 11)).foregroundColor(.gray)
                    }
                }
                Text("若下发后完全无回帧：先把 AAPS 日志里一行 `Write frame, data: …` 的 HEX 贴进上面原样发送，对比回帧即可定位封装差异。")
                    .font(.system(size: 11)).foregroundColor(.gray)
            }
            .padding(16)
        }
    }

    // MARK: - 日志

    private var logTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(ble.logs, id: \.self) { line in
                    Text(line).font(.system(size: 10, design: .monospaced)).foregroundColor(.gray)
                }
            }
            .padding(12)
        }
    }

    // MARK: - 动作

    private func perform(_ action: PendingAction) {
        let addr = ble.bindAddress
        switch action {
        case .bolus(let u):
            ble.send(EquilCommands.setBolus(address: addr, amountTotal: Int(u * 1000), amountExtended: 0, intervalExtended: 0))
        case .stopBolus:
            ble.send(EquilCommands.stopBolus(address: addr))
        case .rewind:
            ble.send(EquilCommands.rewind(address: addr, units: 3))
        case .prime:
            ble.send(EquilCommands.prime(address: addr, units: 2))
        case .stopPump:
            ble.send(EquilCommands.setMode(address: addr, mode: 2))
        case .cancelTemp:
            ble.send(EquilCommands.cancelTemp(address: addr))
        }
    }

    private func runWizardStep(_ step: Int) {
        let addr = ble.bindAddress
        switch step {
        case 0: ble.send(EquilCommands.setMode(address: addr, mode: 0))
        case 1: ble.send(EquilCommands.rewind(address: addr, units: 3))
        case 3: ble.send(EquilCommands.prime(address: addr, units: 2))
        case 4:
            ble.send(EquilCommands.setMode(address: addr, mode: 1))
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "equil_patch_at")
        default: break
        }
    }

    // MARK: - 组件

    private func sectionCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.09, green: 0.12, blue: 0.19))
        .cornerRadius(10)
    }

    private func statusItem(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 15, weight: .semibold))
            Text(title).font(.system(size: 10)).foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cmdButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 12))
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
    }
}
