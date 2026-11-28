import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var ble: BLEManager
    @State private var tab = 0

    @State private var password = UserDefaults.standard.string(forKey: "equil_pwd") ?? "0000"
    @State private var bolusInput = "2.0"
    @State private var tempPercent = "120"
    @State private var tempHours = "1"
    @State private var basalInput = "1.0"
    @State private var rawHex = ""
    @State private var sofText = "7E"
    @State private var escText = "7D"
    @State private var confirm: PendingAction? = nil
    @State private var patchDays = 3
    @State private var wizardStep = 0

    @State private var setExpiry = "72"
    @State private var setAutoOff = "12"
    @State private var setReservoirLow = "20000"
    @State private var setUnitAmount = "50"
    @State private var setBasalLimit = "15000"
    @State private var setBolusLimit = "15000"

    enum PendingAction: Identifiable {
        case bolus(Int)
        case basal(Int)
        case stopBolus
        case rewind
        case prime
        case stopPump
        case cancelTemp
        case syncTime

        var id: String {
            switch self {
            case .bolus(let u): return "bolus-\(u)"
            case .basal(let u): return "basal-\(u)"
            case .stopBolus: return "stopBolus"
            case .rewind: return "rewind"
            case .prime: return "prime"
            case .stopPump: return "stopPump"
            case .cancelTemp: return "cancelTemp"
            case .syncTime: return "syncTime"
            }
        }

        var title: String {
            switch self {
            case .bolus(let mu): return "确认大剂量 \(String(format: "%.2f", Double(mu) / 1000)) U"
            case .basal(let mu): return "确认写入基础率 \(String(format: "%.3f", Double(mu) / 1000)) U/h × 48 槽"
            case .stopBolus: return "确认停止大剂量"
            case .rewind: return "确认退药 3 U（会推回储药器）"
            case .prime: return "确认排气 2 U"
            case .stopPump: return "确认停止输注（模式=停止）"
            case .cancelTemp: return "确认取消临时基础率"
            case .syncTime: return "确认把手机时间写入贴泵"
            }
        }

        var detail: String {
            switch self {
            case .basal: return "会整表覆盖泵内 48 个半小时基础率槽，错了会影响全天输注量，请核对数值。"
            default: return "命令会立即通过蓝牙下发给贴泵，请确认贴泵已贴好。"
            }
        }
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
        .onChange(of: ble.setting?.description ?? "") { _ in
            if let s = ble.setting {
                setExpiry = "\(s.expirationHours)"
                setAutoOff = "\(s.autoOffHours)"
                setReservoirLow = "\(s.reservoirLow)"
                setUnitAmount = "\(s.unitAmount)"
                setBasalLimit = "\(s.basalRateLimit)"
                setBolusLimit = "\(s.bolusAmountLimit)"
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(AppInfo.displayName)
                    .font(.system(size: 17, weight: .semibold))
                Text(AppInfo.versionText)
                    .font(.system(size: 10))
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
                Toggle("只看 EQ 开头的设备", isOn: Binding(
                    get: { ble.onlyEqPrefix },
                    set: { ble.setOnlyEqPrefix($0) }
                ))
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
                    Text(ble.onlyEqPrefix
                         ? "没扫到 EQ 开头的设备（已过滤 \(ble.filteredCount) 个其他设备）。先确认贴泵已唤醒，且原手机 App 已断开；若贴泵名字不是 EQ 开头，可关掉上面的开关。"
                         : "没扫到设备：先确认贴泵已唤醒（贴泵上电/按键），且原手机 App 已断开。")
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

                // 状态（来自 SDK 的 EntityHistory）
                sectionCard("贴泵状态") {
                    HStack {
                        statusItem("模式", modeText)
                        statusItem("电量", ble.history == nil ? "—" : "\(ble.history!.battery)%")
                        statusItem("药量", ble.history == nil ? "—" : "\(ble.history!.reservoir)")
                    }
                    HStack {
                        statusItem("基础率", ble.history == nil ? "—" : String(format: "%.3f U/h", ble.history!.basalRateUnitsPerHour))
                        statusItem("大剂量速度", ble.history == nil ? "—" : String(format: "%.2f U/h", ble.history!.bolusRateUnitsPerHour))
                        statusItem("泵时间", ble.history == nil ? "—" : ble.history!.timeText)
                    }
                    if let h = ble.history {
                        Text("事件：\(h.eventText)")
                            .font(.system(size: 11))
                            .foregroundColor(h.eventLevel >= 2 ? .red : .gray)
                    }
                    Text(patchCountdown).font(.system(size: 11)).foregroundColor(.gray)
                    HStack(spacing: 8) {
                        cmdButton("刷新状态") { ble.send(EquilCommands.queryHistory(address: ble.bindAddress)) }
                        cmdButton("读设置") { ble.send(EquilCommands.querySetting(address: ble.bindAddress)) }
                        cmdButton("阻塞检测") { ble.send(EquilCommands.checkOcclusion(address: ble.bindAddress)) }
                    }
                    if !ble.occlusionText.isEmpty {
                        Text("阻塞检测：\(ble.occlusionText)").font(.system(size: 11)).foregroundColor(.gray)
                    }
                }

                // 设备信息 / 绑定
                sectionCard("设备与绑定") {
                    if let info = ble.deviceInfo {
                        Text(info.description)
                            .font(.system(size: 11, design: .monospaced)).foregroundColor(.gray)
                    } else {
                        Text("先点「读设备」拿到泵内 ID/型号，再写密码。")
                            .font(.system(size: 11)).foregroundColor(.gray)
                    }
                    HStack(spacing: 8) {
                        cmdButton("读设备") { ble.send(EquilCommands.queryDevice(address: ble.bindAddress)) }
                        cmdButton("读模式") { ble.send(EquilCommands.queryMode(address: ble.bindAddress)) }
                    }
                    HStack {
                        Text("泵密码").font(.system(size: 12))
                        TextField("0000", text: $password)
                            .keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                        Button("写入") {
                            guard let info = ble.deviceInfo else {
                                ble.errorText = "先点「读设备」，拿到 20 字节设备信息后才能写密码"
                                return
                            }
                            let model = Self.passwordValue(password)
                            ble.send(EquilCommands.setDeviceModel(address: ble.bindAddress, info: info, model: model))
                            UserDefaults.standard.set(password, forKey: "equil_pwd")
                        }
                        .buttonStyle(.bordered)
                    }
                    Text("密码按 16 进制拼接成 int32（“0000”=0）写入设备 model 字段。")
                        .font(.system(size: 10)).foregroundColor(.gray)
                }

                // 运行控制
                sectionCard("运行控制") {
                    HStack(spacing: 8) {
                        cmdButton("暂停") { ble.send(EquilCommands.setMode(address: ble.bindAddress, mode: 0)) }
                        cmdButton("恢复") { ble.send(EquilCommands.setMode(address: ble.bindAddress, mode: 1)) }
                        cmdButton("停止") { confirm = .stopPump }
                    }
                    HStack(spacing: 8) {
                        cmdButton("同步时间") { confirm = .syncTime }
                        cmdButton("退药 3U") { confirm = .rewind }
                        cmdButton("排气 2U") { confirm = .prime }
                    }
                }

                // 大剂量
                sectionCard("大剂量") {
                    HStack {
                        TextField("单位 U", text: $bolusInput)
                            .keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                        Button("立即输注") {
                            if let u = Double(bolusInput), u > 0, u <= 25 {
                                confirm = .bolus(Int((u * 1000).rounded()))
                            } else {
                                ble.errorText = "大剂量请输入 0～25 U"
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("停止") { confirm = .stopBolus }
                            .buttonStyle(.bordered).foregroundColor(.orange)
                    }
                    if !ble.bolusText.isEmpty {
                        Text("泵内：\(ble.bolusText)").font(.system(size: 11)).foregroundColor(.gray)
                    }
                }

                // 基础率
                sectionCard("基础率") {
                    HStack {
                        TextField("U/h", text: $basalInput)
                            .keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                        Button("写入恒定基础率") {
                            if let v = Double(basalInput), v >= 0, v <= 15 {
                                confirm = .basal(Int((v * 1000).rounded()))
                            } else {
                                ble.errorText = "基础率请填 0～15 U/h"
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("读回") { ble.send(EquilCommands.queryBasal(address: ble.bindAddress)) }
                            .buttonStyle(.bordered)
                    }
                    if !ble.basalUnits.isEmpty {
                        Text("泵内 48 槽：\(basalSummary(ble.basalUnits))")
                            .font(.system(size: 10, design: .monospaced)).foregroundColor(.gray)
                    } else {
                        Text("48 个半小时槽会是同一个值；写私有分段基础率需要另做表格编辑。")
                            .font(.system(size: 10)).foregroundColor(.gray)
                    }
                }

                // 临时率
                sectionCard("临时基础率（百分比）") {
                    HStack {
                        TextField("百分比 %", text: $tempPercent)
                            .keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                        TextField("时长 h", text: $tempHours)
                            .keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                        Button("下发") {
                            if let p = Int(tempPercent), let h = Double(tempHours), p > 0, p <= 500, h > 0, h <= 24 {
                                ble.send(EquilCommands.setTempPercent(address: ble.bindAddress, percent: p, seconds: Int(h * 3600)))
                            } else {
                                ble.errorText = "百分比 1～500，时长 0～24 小时"
                            }
                        }.buttonStyle(.borderedProminent)
                        Button("取消") { confirm = .cancelTemp }.buttonStyle(.bordered)
                    }
                    if !ble.tempText.isEmpty {
                        Text("泵内：\(ble.tempText)").font(.system(size: 11)).foregroundColor(.gray)
                    }
                }

                // 设置
                sectionCard("泵内设置（16 字节）") {
                    settingRow("贴片到期 h", $setExpiry, keyboard: .numberPad)
                    settingRow("自动关机 h", $setAutoOff, keyboard: .numberPad)
                    settingRow("药量低限 mU", $setReservoirLow, keyboard: .numberPad)
                    settingRow("单次量 mU", $setUnitAmount, keyboard: .numberPad)
                    settingRow("基础率上限 mU/h", $setBasalLimit, keyboard: .numberPad)
                    settingRow("大剂量上限 mU", $setBolusLimit, keyboard: .numberPad)
                    Button("写入设置") {
                        var s = ble.setting ?? EquilSetting()
                        s.expirationHours = Int32(setExpiry) ?? s.expirationHours
                        s.autoOffHours = Int32(setAutoOff) ?? s.autoOffHours
                        s.reservoirLow = Int(setReservoirLow) ?? s.reservoirLow
                        s.quickBolusStep = s.quickBolusStep > 0 ? s.quickBolusStep : 50
                        s.unitAmount = Int(setUnitAmount) ?? s.unitAmount
                        s.basalRateLimit = Int(setBasalLimit) ?? s.basalRateLimit
                        s.bolusAmountLimit = Int(setBolusLimit) ?? s.bolusAmountLimit
                        ble.send(EquilCommands.setSetting(address: ble.bindAddress, setting: s))
                    }
                    .buttonStyle(.bordered)
                    if let s = ble.setting {
                        Text(s.description).font(.system(size: 10)).foregroundColor(.gray)
                    }
                }

                // 换片
                sectionCard("换片 / 维护") {
                    Text("顺序：停止 → 退药 → 取旧片 → 装新片 → 排气 → 恢复 → 记录。")
                        .font(.system(size: 11)).foregroundColor(.gray)
                    Button(wizardStep == 0 ? "开始换片向导（6 步）" : "下一步（\(min(wizardStep, 6))/6）：\(wizardText)") {
                        nextWizard()
                    }
                    .buttonStyle(.bordered)
                    Button("记录已换片（重置 3 天倒计时）") {
                        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "equil_patch_at")
                    }
                    .font(.system(size: 12))
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

    private var wizardText: String {
        switch wizardStep {
        case 1: return "已暂停，下一步退药 3U"
        case 2: return "请取旧片、装新片"
        case 3: return "装好后排气 2U"
        case 4: return "排气完成，准备恢复"
        case 5: return "将恢复运行并记录"
        case 6: return "点一次记录换片"
        default: return "准备"
        }
    }

    private var patchCountdown: String {
        let at = UserDefaults.standard.double(forKey: "equil_patch_at")
        guard at > 0 else { return "未记录换片时间" }
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
                            ble.log("帧参数 SOF=\(sofText) ESC=\(escText)")
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
                sectionCard("最近回帧") {
                    ForEach(ble.frames.prefix(10), id: \.self) { f in
                        Text(f).font(.system(size: 10, design: .monospaced)).foregroundColor(.gray)
                    }
                    if ble.frames.isEmpty {
                        Text("还没有收到数据").font(.system(size: 11)).foregroundColor(.gray)
                    }
                }
                Text("若下发后完全无回帧：把 AAPS 日志里一行 `Write frame, data: …` 的 HEX 贴进上面原样发送，对比回帧即可定位封装差异。")
                    .font(.system(size: 11)).foregroundColor(.gray)
            }
            .padding(16)
        }
    }

    // MARK: - 日志

    private var logTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(ble.logs.indices, id: \.self) { i in
                    Text(ble.logs[i]).font(.system(size: 10, design: .monospaced)).foregroundColor(.gray)
                }
            }
            .padding(12)
        }
    }

    // MARK: - 动作

    private func perform(_ action: PendingAction) {
        let addr = ble.bindAddress
        switch action {
        case .bolus(let mu):
            ble.send(EquilCommands.setBolus(address: addr, totalMiliUnits: mu))
        case .basal(let mu):
            ble.send(EquilCommands.constantBasal(address: addr, unitsPerHour: Double(mu) / 1000))
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
        case .syncTime:
            ble.send(EquilCommands.setDateTime(address: addr))
        }
    }

    private func nextWizard() {
        let addr = ble.bindAddress
        if wizardStep == 0 {
            wizardStep = 1
            ble.send(EquilCommands.setMode(address: addr, mode: 0))
            return
        }
        switch wizardStep {
        case 1:
            ble.send(EquilCommands.rewind(address: addr, units: 3))
        case 3:
            ble.send(EquilCommands.prime(address: addr, units: 2))
        case 5:
            ble.send(EquilCommands.setMode(address: addr, mode: 1))
        case 6:
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "equil_patch_at")
            wizardStep = 0
            return
        default:
            break
        }
        wizardStep = min(6, wizardStep + 1)
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
            Text(value).font(.system(size: 14, weight: .semibold))
            Text(title).font(.system(size: 10)).foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingRow(_ title: String, _ text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        HStack {
            Text(title).font(.system(size: 11)).foregroundColor(.gray)
            Spacer()
            TextField("", text: text)
                .keyboardType(keyboard)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
        }
    }

    private func cmdButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 12))
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
    }

    private func basalSummary(_ units: [Double]) -> String {
        guard let first = units.first, let last = units.last else { return "—" }
        if abs(first - last) < 0.0001 {
            return String(format: "恒定 %.3f U/h", first)
        }
        let minU = units.min() ?? 0
        let maxU = units.max() ?? 0
        return String(format: "%.3f ~ %.3f U/h", minU, maxU)
    }

    /// 4 位数字密码按 16 进制解析成 int32（“0000”→0，“1234”→0x1234）
    static func passwordValue(_ text: String) -> Int32 {
        let digits = text.filter { $0.isHexDigit }
        guard !digits.isEmpty, let v = Int32(digits, radix: 16) else { return 0 }
        return v
    }
}
