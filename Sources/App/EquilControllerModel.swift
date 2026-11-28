import Foundation
import Combine
import CoreBluetooth
import os

/// View model wiring EquilBLEManager + EquilCommandRunner to the SwiftUI controller.
/// Streams every log line to the UI and to os_log (so `log stream` on the Mac sees it too).
/// 泵的运行模式。对应 AAPS 4.0 的 `app.aaps.pump.equil.data.RunMode`。
enum EquilRunMode: String {
    case run     = "RUN"
    case suspend = "SUSPEND"
    case stop    = "STOP"
    case unknown = "—"

    /// 界面文案。日志里仍用 rawValue（RUN / SUSPEND / STOP），排查时和 AAPS 对得上。
    var displayName: String {
        switch self {
        case .run:     return "运行中"
        case .suspend: return "已暂停"
        case .stop:    return "已停止"
        case .unknown: return "—"
        }
    }

    /// CmdModelSet 的 mode 参数。
    var command: Int {
        switch self {
        case .run:      return 1
        case .suspend:  return 0
        case .stop:     return 2
        case .unknown:  return 1
        }
    }
}

/// 一次大剂量记录。元组无法直接用于 @Published 的相等性判断，用结构体。
struct BolusRecord: Equatable {
    var units: Double
    var at: Date
}

/// 正在推注的大剂量。
///
/// 泵的 bolus 命令只发一次：总脉冲数 + 每单位用多少秒。泵 ACK 之后连接就断了，
/// 它自己按 stepTime 匀速推完 —— 这期间界面不会有任何变化，用户很容易以为已经结束，
/// 其实还在推。也正因为连接断了，想中途停必须**另发一条停止命令**
/// （`CmdLargeBasalSet(0)`，AAPS 的 `stopBolus` 就是这么做的）。
struct BolusDelivery: Equatable {
    /// 计划总量（U）。
    let units: Double
    /// 泵 ACK 的时刻 —— 推注从这里开始算。
    let startedAt: Date
    /// 预计总时长（秒）= 总量 × 每单位秒数。
    let seconds: Double

    /// 按时间线性估算已推量。
    ///
    /// 泵不回传「当前推到第几脉冲」，只能这样估。前提是 stepTime 均匀，
    /// 这一点固件保证了（它是把总时长均分到每个脉冲）。
    func delivered(at now: Date) -> Double {
        guard seconds > 0 else { return units }
        let elapsed = now.timeIntervalSince(startedAt)
        return min(units, max(0, units * elapsed / seconds))
    }

    func remaining(at now: Date) -> TimeInterval {
        max(0, seconds - now.timeIntervalSince(startedAt))
    }

    func isFinished(at now: Date) -> Bool {
        remaining(at: now) <= 0
    }
}

@MainActor
final class EquilControllerModel: ObservableObject {

    // MARK: UI state
    @Published var logLines: [String] = []
    @Published var btState: String = "未知"
    /// 6 位十六进制序列号。**不再由用户手输**——扫描到泵时从广播名解析
    /// （`Equil - A1B2C3` → `A1B2C3`），或用上次配对保存的值。
    /// 仍要留在 @Published 里，因为它参与排气阻力档位判断和审计日志。
    @Published var serialNumber: String = ""
    /// 4 位十六进制配对密码（可留空）。用户自定、配对时写进泵，解绑时还要用；
    /// 泵身标签上没有密码，别让人去翻标签。
    @Published var pairPassword: String = ""
    @Published var maxBolus: String = "25"            // 单次大剂量上限（U）
    @Published var maxBasal: String = "15"            // 基础率上限（U/h）
    @Published var bolusUnits: String = "0.05"
    @Published var tempRate: String = "0.5"           // 临时基础率速率（U/h）
    @Published var tempDuration: String = "30"        // 临时基础率时长（分钟）
    @Published var busy: Bool = false
    @Published var statusLine: String = "待机"

    /// 批量流程深度（>0 时单条命令结束不放开 `busy`）。
    ///
    /// 「刷新」实际是三条命令（运行模式 → 电池/余量 → 临时基础率）。
    /// 以前每条命令各自 `busy = true/false`，两条之间还留 400 ms 间隙，
    /// 于是界面上的按钮会「灰—亮—灰—亮—灰」闪三次，看着像卡住。
    /// 现在整批只持有一次 busy，中间不再亮回来。
    private var batchDepth = 0

    /// 结束一条命令时调用：批量期间交给最外层收尾。
    private func releaseBusy() {
        if batchDepth > 0 { return }
        busy = false
    }

    // MARK: - 安全闸门 / 审计（本版新增）
    //
    //  所有输注类命令都必须先过 SafetyGuard.evaluate()。UI 只调用 sendBolus()，
    //  内部按结论分流：直接拒绝 / 弹长按确认页 / 放行。
    let safety = SafetyGuard()
    private let audit = AuditLog.shared

    /// 临时基础率倒计时用的分钟级心跳（不连泵，纯本地算）。
    private var tempBasalTicker: Timer?

    /// 最近一次**从泵读到**的余量（U）。nil = 从未成功读取。
    ///
    /// 这个值只有一个来源：泵回传的 `data[6]` / `data[13]`（整数单位）。
    /// 绝不在本地按输注量做减法 —— 泵的余量字段是整数，本机相减会越差越多
    /// （0.4 U 四舍五入成 0，打几十次软件仍显示满），而且基础率、排气、
    /// 泵自己停输都在消耗，只有泵知道真实剩余。
    @Published var reservoirUnits: Int?
    /// 上面那个数字的读取时刻。显示时必须带上，否则用户无法判断新旧。
    @Published var reservoirReadAt: Date?
    /// 最近一次确认的泵运行模式。nil = 未查询过。
    @Published var pumpIsRunning: Bool?

    // MARK: - 概览页状态（对应 AAPS 4.0 PumpOverviewUiState 的字段来源）
    //
    //  AAPS 的概览页显示 10 行信息，这些是它们的来源。凡是尚未读过的一律留 nil，
    //  UI 显示「—」，绝不显示 0 或假值——读数缺失和读数为 0 是两件事。
    @Published var runMode: EquilRunMode = .unknown
    /// 固件版本。CmdPair / CmdHistoryGet 回包里带。
    @Published var firmwareVersion: String?
    /// 最后一次成功通信的时间。
    @Published var lastDataTime: Date?
    /// 电池百分比。
    @Published var batteryPercent: Int?
    /// 基础率（U/h）。AAPS 显示 3 位小数。
    @Published var baseBasalRate: Double?
    /// 起始储药量（U）。-1 / nil 表示未知，此时算不出总输注量。
    @Published var startInsulin: Int?
    /// 最近一次大剂量。
    @Published var lastBolus: BolusRecord?

    /// 正在推注的大剂量。nil = 空闲。
    ///
    /// `busy` 只覆盖「命令下发」那几秒；泵 ACK 后要自己推几分钟，这段时间
    /// 必须单独跟踪，否则既看不到进度，也没有停止的入口。
    @Published var bolusDelivery: BolusDelivery?
    /// 进度心跳。值本身不重要，只为了让界面每秒重画一次。
    @Published var bolusTick: Date = Date()
    private var bolusTicker: Timer?
    /// 配对流程是否走完（含最后的 CmdModelSet RUN）。
    @Published var activationCompleted: Bool = false
    /// 本次流程是否**已经排气到位**（阻力达到阈值）。
    ///
    /// 之前向导拿 `activationCompleted` 当"排气完成"，但那个标志只有 RUN 成功才会置位，
    /// 于是排气做完、按钮又变回「开始排气」，永远进不了下一步。
    /// 排气和 RUN 是两件事，分开记。
    @Published var primeCompleted: Bool = false

    /// 临时基础率摘要（速率 + 剩余分钟）。nil = 当前无临时基础率或未查询。
    @Published var tempBasalRate: Double?
    @Published var tempBasalRemainingMin: Int?
    /// 临时基础率结束时刻。有这个才能自己倒计时 —— 泵只在回读那一刻给出
    /// 「剩余秒数」，读完整页不动就会一直显示那个数字。
    @Published var tempBasalUntil: Date?
    /// 最近一次下发/回读的时刻，用于判断读数新旧。
    @Published var tempBasalSetAt: Date?
    /// true = 刚下发、还没回读确认（泵的确认包里没有状态位，只能靠回读）。
    @Published var tempBasalPendingVerify: Bool = false

    /// 给概览页用的一行摘要。AAPS 用 basalTbrString 拼，这里给出等价文本。
    var tempBasalSummary: String? {
        guard let rate = tempBasalRate else { return nil }
        if let remain = tempBasalRemainingMin {
            return String(format: "%.2f U/h · 剩 %d 分钟", rate, remain)
        }
        return String(format: "%.2f U/h", rate)
    }

    // MARK: - 导航（对应 AAPS EquilComposeContent 的三个屏幕状态）

    enum Route {
        case overview
        case history
        case wizardPair
        case wizardChange
        case wizardUnpair
    }

    @Published var route: Route = .overview
    /// 大剂量输入页。
    @Published var showBolusSheet: Bool = false
    /// 参数设置页（图3 那个「参数设置 / 写入」）。
    @Published var showSettings: Bool = false
    /// 实时日志页。
    @Published var showLogSheet: Bool = false
    /// 扫描页。用 sheet 呈现，而不是塞进 route——
    /// 向导内部再 push 一层在同一套 navigationDestination 上会失灵。
    @Published var showScanner: Bool = false

    /// 顶栏展示的完整状态摘要，AAPS 用的是 CommunicationStatusCard。
    var connectionSummary: String {
        guard isPaired else { return "未配对" }
        if !activationCompleted { return "已配对 · 未初始化" }
        return "已配对 · \(runMode.displayName)"
    }
    /// 非 nil 时弹出确认页，值为待确认剂量。
    @Published var pendingBolus: Double?
    /// 待确认的方波时长（分钟）。nil = 常规大剂量。
    @Published var pendingExtendedMinutes: Int?
    /// 确认页上展示的原因。
    @Published var pendingReason: String = ""
    /// 本机记账：正在执行的方波结束时刻与总量（泵没有「查方波」的命令，
    /// 只能靠下发成功后自己记；撤销时以泵的回执为准）。
    @Published var extendedBolusEnd: Date?
    @Published var extendedBolusUnits: Double = 0

    /// 方波时长范围（分钟）。AAPS 的 CmdExtendedBolusSet 直接发
    /// `durationInMinutes * 60` 秒，没有粒度限制；这里只卡上下界。
    static let extendedMinutesRange = 1...480
    /// 被闸门拦下的原因，UI 弹 alert 用。读取后请置 nil。
    @Published var blockReason: String?

    // MARK: 输入校验（AAPS 正则：4 位十六进制，允许留空）
    //
    //  SN 不再由用户输入，所以没有「SN 格式对不对」这回事了；
    //  它是从广播名解析出来的，解析不出就是 nil，由扫描页提示。
    //
    //  密码是**可选**的（AAPS 4.0 PasswordStep：isPasswordValid = isEmpty || 4位HEX）。
    //  它由用户自定、配对时写进泵，将来解绑也要用；泵身标签上没有这个东西。
    var pairPasswordValid: Bool {
        pairPassword.isEmpty || pairPassword.range(of: "^[0-9A-Fa-f]{4}$", options: .regularExpression) != nil
    }

    // MARK: Stored pairing result (device/password negotiated during pairing)
    @Published var pairedDevice: String = ""
    @Published var pairedPassword: String = ""

    /// 是否已配对。AAPS 用 serialNumber 判空，这里用协商到的 device——没有 device
    /// 就发不出任何命令，比 SN 输入框里有没有字更能反映真实状态。
    var isPaired: Bool { !pairedDevice.isEmpty && !pairedPassword.isEmpty }

    // MARK: 扫描 — 默认只报 Equil 泵，诊断模式才列出全部 BLE 设备
    struct DiscoveredDevice: Identifiable, Equatable {
        let id: String          // peripheral identifier (uuid)
        let name: String        // 广播名原文
        var rssi: Int
        /// 从广播名解析出的 6 位 SN。nil = 名字里读不出 SN（不是泵，或固件不广播）。
        var serial: String?
        /// 与已保存的 SN 一致（说明这就是上次配对的那台）。
        var matchesSerial: Bool
    }
    @Published var scanning: Bool = false
    @Published var discovered: [DiscoveredDevice] = []
    /// 被过滤器挡掉的设备数量。用来证明过滤确实在工作。
    @Published var filteredOut: Int = 0
    /// 诊断开关：列出附近全部 BLE 设备（默认关闭，只显示 Equil）。
    @Published var showAllDevices: Bool = false

    // MARK: 选中设备（用户在扫描列表里点的那一台）
    //
    //  AAPS 4.0 的配对流程是「扫描 → 点选泵 → 输密码」，没有手动填 SN 这一步：
    //  SN 本来就印在广播名里。照搬这个流程后，标签上什么都不用抄。
    @Published var selectedDevice: DiscoveredDevice?
    /// peripheral 对象只在这里缓存，DiscoveredDevice 保持值语义（Equatable）。
    private var peripheralCache: [String: CBPeripheral] = [:]

    /// 选中设备的展示名，用来在设置页和概览页回显。
    var selectedDeviceLabel: String? {
        guard let d = selectedDevice else { return nil }
        return d.name
    }

    /// 是否具备开始配对的条件：选了一台泵 + 密码格式合法。
    var canStartPairing: Bool {
        selectedDevice != nil && pairPasswordValid
    }

    /// 用户在扫描列表里点选一台泵。
    func selectDevice(_ dev: DiscoveredDevice) {
        selectedDevice = dev
        if let sn = dev.serial, sn != serialNumber {
            serialNumber = sn
            append("🔗 已选中 \(dev.name) — 解析出 SN=\(sn)")
        } else if dev.serial == nil {
            append("🔗 已选中 \(dev.name) — 广播名里没有 SN，配对时用完整名称")
        } else {
            append("🔗 已选中 \(dev.name)")
        }
        persistIdentity()
    }

    /// 进入配对向导的扫描步：清掉上一次的残影并重新扫一遍。
    ///
    /// 严格按 AAPS：只有「本次扫描真的看到、并被用户点选」的泵才允许往下走。
    /// 从 UserDefaults 恢复的旧选择不算数——那台泵可能已经不在旁边了。
    func restartPairScan() {
        guard !busy else { return }
        selectedDevice = nil
        discovered.removeAll()
        peripheralCache.removeAll()
        pairingState = .idle
        persistIdentity()
        startScan()
    }

    private let ble = EquilBLEManager()
    private lazy var runner = EquilCommandRunner(ble: ble)
    private let oslog = Logger(subsystem: "app.equil.controller", category: "Equil")

    // MARK: 内置 HTTP 日志服务器（电脑上 curl http://<手机IP>:8080）
    let logServer = LogServer()
    @Published var logURL: String = "日志服务器启动中…"

    init() {
        ble.onStateChange = { [weak self] state in
            Task { @MainActor in self?.btState = Self.describe(state) }
        }
        runner.onLog = { [weak self] line in
            Task { @MainActor in self?.append(line) }
        }
        ble.onLog = { [weak self] line in
            Task { @MainActor in self?.append("[BLE] \(line)") }
        }
        // 接入协议诊断日志（decode 步骤、runPwd/runCode/payload）。
        EquilBaseCmd.debugLog = { [weak self] line in
            Task { @MainActor in self?.append(line) }
        }
        // 启动内置日志服务器 — 电脑上：curl http://<手机IP>:8080
        logServer.start(port: 8080)
        if let ip = logServer.ipAddress {
            logURL = "http://\(ip):8080"
        } else {
            logURL = "Wi-Fi IP 不可用（端口 8080）"
        }
        append("📡 日志服务器：\(logURL)")
        audit.record(.appLaunch, note: "controller started")
        loadIdentity()
        loadPumpConfig()
    }

    // MARK: - 泵身份（SN / 配对密码）持久化
    //
    //  原来 SN 与密码只存在内存里，重启就没了，而设置页又没有入口，
    //  结果就是「向导第 2 步永远显示未填写」。现在两处都能填，并且落盘。

    private enum IdentityKeys {
        static let serial     = "equil.identity.serial"
        static let password   = "equil.identity.password"
        static let showAll    = "equil.scan.showAllDevices"
        static let pairedDev  = "equil.identity.pairedDevice"
        // CmdPair 协商出来的新密码，和用户输入的 4 位不同。
        // 以前只存在内存里，杀进程后 isPaired 变 false，于是「已经配对好的泵又要重配」。
        static let pairedPwd  = "equil.identity.pairedPassword"
        /// 是否已经完成过初始化（RUN 成功）。同样要落盘，否则重启后大剂量按钮一直是灰的。
        static let activated  = "equil.identity.activationCompleted"
        static let selName    = "equil.identity.selectedName"
        static let selID      = "equil.identity.selectedID"
        static let firmware   = "equil.identity.firmware"
        /// 本次敷贴的起始储药量（U），用于算「总输送量」。换敷贴/重配时清空。
        static let startInsulin = "equil.pump.startInsulin"
    }

    /// 从 UserDefaults 恢复泵号、密码、扫描偏好、已配对设备、上次选中的泵。
    func loadIdentity() {
        let d = UserDefaults.standard
        if let s = d.string(forKey: IdentityKeys.serial), !s.isEmpty {
            serialNumber = s
        }
        if let p = d.string(forKey: IdentityKeys.password), !p.isEmpty {
            pairPassword = p
        }
        if let pd = d.string(forKey: IdentityKeys.pairedDev), !pd.isEmpty, pairedDevice.isEmpty {
            pairedDevice = pd
        }
        if let pp = d.string(forKey: IdentityKeys.pairedPwd), !pp.isEmpty, pairedPassword.isEmpty {
            pairedPassword = pp
        }
        if d.bool(forKey: IdentityKeys.activated) {
            activationCompleted = true
        }
        if d.object(forKey: IdentityKeys.startInsulin) != nil {
            startInsulin = d.integer(forKey: IdentityKeys.startInsulin)
        }
        // 固件版本是可缓存的：泵不会自己升级，读到一次就一直有效，
        // 直到下次读取覆盖它。缓存的用处是没连泵时概览页也有东西可看。
        if let fv = d.string(forKey: IdentityKeys.firmware), !fv.isEmpty {
            firmwareVersion = fv
        }
        // 上次选中的泵：把名字和 SN 恢复出来，用户重开 App 不用再扫一遍。
        // 这里没有 peripheral 句柄，真正配对时 runner 会退回按名称扫描。
        if let nm = d.string(forKey: IdentityKeys.selName), !nm.isEmpty {
            let id = d.string(forKey: IdentityKeys.selID) ?? ""
            selectedDevice = DiscoveredDevice(
                id: id, name: nm, rssi: 0,
                serial: serialNumber.isEmpty ? nil : serialNumber,
                matchesSerial: true
            )
        }
        showAllDevices = d.bool(forKey: IdentityKeys.showAll)
    }

    /// 落盘。SN/密码/扫描偏好/选中设备改动后调用。
    func persistIdentity() {
        let d = UserDefaults.standard
        d.set(serialNumber.trimmingCharacters(in: .whitespaces).uppercased(),
              forKey: IdentityKeys.serial)
        d.set(pairPassword.trimmingCharacters(in: .whitespaces).uppercased(),
              forKey: IdentityKeys.password)
        d.set(showAllDevices, forKey: IdentityKeys.showAll)
        d.set(pairedDevice, forKey: IdentityKeys.pairedDev)
        d.set(pairedPassword, forKey: IdentityKeys.pairedPwd)
        d.set(activationCompleted, forKey: IdentityKeys.activated)
        if let start = startInsulin {
            d.set(start, forKey: IdentityKeys.startInsulin)
        } else {
            d.removeObject(forKey: IdentityKeys.startInsulin)
        }
        d.set(selectedDevice?.name ?? "", forKey: IdentityKeys.selName)
        d.set(selectedDevice?.id ?? "", forKey: IdentityKeys.selID)
    }

    /// 规范化输入：去掉非 hex 字符、转大写、截断到规定长度。
    /// 粘贴带空格或小写的串（"a1 b2 c3"）也能直接用。
    /// nonisolated：要能在 SwiftUI 的 Binding setter 里同步调用。
    nonisolated static func normalizeHex(_ raw: String, length: Int) -> String {
        let hex = raw.uppercased().filter { "0123456789ABCDEF".contains($0) }
        return String(hex.prefix(length))
    }

    // MARK: - 泵侧参数（CmdAlarmSet + CmdSettingSet）
    //
    //  与 SafetyGuard 分开：SafetyGuard 是 App 自己的闸门，掉电即失效；
    //  这里写进去的值存在泵里，换手机也还在。

    @Published var pumpConfig = PumpConfig()
    /// 上一次成功把参数写进泵的时间。nil = 没写过（或不知道泵里现在是什么）。
    @Published var lastSettingsWrite: Date?

    private enum PumpConfigKeys {
        static let config = "equil.pump.config.v1"
        static let wrote  = "equil.pump.config.lastWrite"
        /// 1.5 版把两个默认值改掉（低药量 16→10、速度 1.5→3 U/min）。
        /// 老用户机器上存的是旧默认值，光改代码不会生效，所以做一次迁移。
        static let migrated = "equil.pump.config.migrated.defaults.v15"
        /// 1.6 版把报警方式默认改静音。和上一条分开记，否则已经升过 1.5
        /// 的机器上标记早就置位了，静音这条永远轮不到。
        static let migratedAlarm = "equil.pump.config.migrated.defaults.v16"
        /// 1.12 版定稿：App 侧单次上限回到 10 U，每小时累计 20→30、
        /// 最短间隔 120→60、余量保留 5→10。泵侧最大大剂量仍是 10 U。
        /// 分开记，理由同上。
        static let migratedDoseDefaults = "equil.pump.config.migrated.defaults.v112"
    }

    func loadPumpConfig() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: PumpConfigKeys.config),
           let cfg = try? JSONDecoder().decode(PumpConfig.self, from: data) {
            pumpConfig = cfg.sanitized()
        }
        migrateDefaultsIfNeeded()
        migrateAlarmDefaultIfNeeded()
        migrateDoseDefaultsIfNeeded()
        lastSettingsWrite = d.object(forKey: PumpConfigKeys.wrote) as? Date
    }

    /// 只在「值仍等于旧默认值」时迁移：用户手动选过 16 U / 1.5 U/min
    /// 的情况无法与旧默认区分，但这种情况下改掉也只是回到新默认，可接受；
    /// 而用户明确选过 3 U/min 或 10 U 的，值不匹配，不会被覆盖。
    private func migrateDefaultsIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: PumpConfigKeys.migrated) else { return }
        var cfg = pumpConfig
        if cfg.lowReservoir == 16 { cfg.lowReservoir = 10 }
        if cfg.bolusSecondsPerUnit == EquilConst.EQUIL_BOLUS_SECONDS_PER_UNIT_STANDARD {
            cfg.bolusSecondsPerUnit = BolusSpeed.fast.rawValue
        }
        pumpConfig = cfg.sanitized()
        persistPumpConfig()
        d.set(true, forKey: PumpConfigKeys.migrated)
    }

    /// 报警方式默认从「声音和震动」改成「静音」。同样只在值等于旧默认时才动，
    /// 免得把别人特意选的「震动」也一起改掉。
    private func migrateAlarmDefaultIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: PumpConfigKeys.migratedAlarm) else { return }
        var cfg = pumpConfig
        if cfg.alarmModeRaw == EquilAlarmMode.toneAndShake.rawValue {
            cfg.alarmModeRaw = EquilAlarmMode.mute.rawValue
        }
        pumpConfig = cfg.sanitized()
        persistPumpConfig()
        d.set(true, forKey: PumpConfigKeys.migratedAlarm)
    }

    /// 1.10 版把一组剂量相关的默认值调大/调小。同样只在「值仍等于旧默认」时迁移，
    /// 用户明确改过的数值不会被覆盖。
    ///
    /// 副作用：如果用户恰好把某一项手工调成了旧默认值（比如把单次上限从 8 调回 10），
    /// 这次迁移也会把它当成"没改过"而换成新默认。四项一起变，升级后请到设置页核对一遍。
    private func migrateDoseDefaultsIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: PumpConfigKeys.migratedDoseDefaults) else { return }

        // 1.11 曾把 App 侧单次上限默认放到 25，1.12 收回 10：只有当前值
        // 正好是 25 才回退。泵侧「允许的最大大剂量值」始终是 10 U 不动 ——
        // 它是泵固件的硬限制，也是最后一道兜底。
        if safety.maxSingleDose == 25 { safety.maxSingleDose = 10 }
        if safety.maxPerHour == 20 { safety.maxPerHour = 30 }
        if safety.minInterval == 120 { safety.minInterval = 60 }
        if safety.reservoirReserve == 5 { safety.reservoirReserve = 10 }
        safety.persistSettings()

        d.set(true, forKey: PumpConfigKeys.migratedDoseDefaults)
    }

    func persistPumpConfig() {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(pumpConfig.sanitized()) {
            d.set(data, forKey: PumpConfigKeys.config)
        }
        d.set(lastSettingsWrite, forKey: PumpConfigKeys.wrote)
    }

    /// 把参数写进泵：先 CmdAlarmSet（报警方式），成功后再 CmdSettingSet（剂量阈值）。
    /// 两条命令各建一次连接（connect-per-command），所以必须串行。
    func writePumpSettings() {
        guard !busy else { return }
        guard !pairedDevice.isEmpty, !pairedPassword.isEmpty else {
            append("⚠️ 还没配对，参数写不进去。先走一遍配对向导。")
            statusLine = "未配对"
            return
        }
        let cfg = pumpConfig.sanitized()
        // 只提示，不阻断：闸门已改成按 min(单次上限, 泵侧上限) 判断，
        // 不会再出现「App 放行、泵拒绝」。泵侧是固件硬限制，按它写就行。
        if let conflict = cfg.conflict(withMaxSingleDose: safety.maxSingleDose) {
            append(String(format: "ⓘ %@（本次仍按泵侧 %.0f U 写入，App 会在 %.0f U 处就拦）",
                          conflict, cfg.maxBolus, min(safety.maxSingleDose, cfg.maxBolus)))
        }
        pumpConfig = cfg
        busy = true
        statusLine = "写入参数 1/2：报警方式…"
        append("=== 写入泵参数 1/2：报警方式=\(cfg.alarmMode.label) ===")
        let alarm = CmdAlarmSet(mode: cfg.alarmModeRaw,
                                createTime: Int64(Date().timeIntervalSince1970 * 1000),
                                equilDevice: pairedDevice,
                                equilPassword: pairedPassword)
        runCommandPerConnection(alarm, kind: "报警方式") { [weak self] outcome in
            guard let self else { return }
            self.handle(outcome, kind: "报警方式")
            switch outcome {
            case .success:
                self.writeThresholds()
            case .failure(let msg):
                self.append("❌ 参数写入中止：报警方式失败（\(msg)）。剂量阈值没有下发，泵里仍是旧值。")
                self.statusLine = "参数写入失败"
                self.busy = false
            }
        }
    }

    private func writeThresholds() {
        let cfg = pumpConfig
        statusLine = "写入参数 2/2：剂量阈值…"
        append(String(format: "=== 写入泵参数 2/2：最大大剂量 %.2f U、最大基础率 %.2f U/h、低药量报警 %.1f U ===",
                      cfg.maxBolus, cfg.maxBasal, cfg.lowReservoir))
        let cmd = CmdSettingSet(maxBolus: cfg.maxBolus,
                                maxBasal: cfg.maxBasal,
                                lowAlarm: cfg.lowReservoir,
                                equilDevice: pairedDevice,
                                equilPassword: pairedPassword,
                                createTime: Int64(Date().timeIntervalSince1970 * 1000))
        runCommandPerConnection(cmd, kind: "剂量阈值") { [weak self] outcome in
            guard let self else { return }
            self.handle(outcome, kind: "剂量阈值")
            switch outcome {
            case .success:
                self.lastSettingsWrite = Date()
                self.persistPumpConfig()
                self.append("✅ 泵参数已写入（报警=\(cfg.alarmMode.label)，大剂量上限=\(String(format: "%.0f", cfg.maxBolus)) U，基础率上限=\(String(format: "%.1f", cfg.maxBasal)) U/h，低药量=\(String(format: "%.0f", cfg.lowReservoir)) U）")
                self.statusLine = "参数已写入"
            case .failure(let msg):
                self.append("❌ 剂量阈值写入失败：\(msg)")
                self.statusLine = "参数写入失败"
            }
            self.busy = false
        }
    }

    // MARK: Actions
    /// 配对状态。向导用它决定「配对中 / 成功 / 失败」的显示，
    /// 不然用户点完「开始配对」只看到按钮变灰，不知道发生了什么。
    enum PairingState: Equatable {
        case idle
        case running
        case paired
        case failed(String)
    }
    @Published var pairingState: PairingState = .idle

    /// 完整 4 步配对（与 AAPS 一致）：连接选中的泵 → CmdDevicesOldGet →
    /// CmdPair → CmdSettingSet。SN 来自广播名，密码来自用户输入。
    func startPairing() {
        guard !busy else { return }
        guard let dev = selectedDevice else {
            append("⚠️ 还没有选中泵。先扫描，然后在列表里点一下你的泵。")
            statusLine = "未选择设备"
            return
        }
        guard pairPasswordValid else {
            append("⚠️ 密码无效（留空，或 4 位十六进制如 0000）")
            statusLine = "密码无效"
            return
        }
        // 配对时顺带把「参数设置」里的阈值写进泵，避免配对完泵侧上限
        // 还是出厂的 25 U / 15 U/h，而 App 侧以为已经是自己的设置。
        let mb = pumpConfig.maxBolus
        let mbas = pumpConfig.maxBasal
        busy = true
        pairingState = .running
        statusLine = "配对进行中…"
        append("=== 配对开始（设备=\(dev.name)，SN=\(dev.serial ?? "未解析")，密码=\(pairPassword)）===")

        let target = peripheralCache[dev.id]
        if target == nil {
            append("⚠️ 设备句柄已失效（App 可能被系统回收过），改为按名称重新扫描")
        }

        runner.runPairing(serialNumber: dev.serial ?? "",
                          advertisedName: dev.name,
                          password: pairPassword,
                          maxBolus: mb,
                          maxBasal: mbas,
                          targetPeripheral: target,
                          timeout: 90) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success(let enacted):
                self.busy = false
                self.pairingState = .paired
                self.pairedDevice = self.runner.pairedDevice ?? ""
                self.pairedPassword = self.runner.pairedPassword ?? ""
                self.statusLine = "配对：成功"
                self.append("✅ 配对成功（enacted=\(enacted)）")
                self.append("已保存设备=\(self.runner.pairedDevice ?? "?")")
                self.append("已保存密码=\(self.runner.pairedPassword ?? "?")")
                self.persistIdentity()
                self.activateWatchdogAfterPairing()
            case .failure(let msg):
                self.busy = false
                self.pairingState = .failed(msg)
                self.statusLine = "配对：失败 — \(msg)"
                self.append("❌ 配对失败：\(msg)")
            }
            // 不管配对最终成没成，第 1 步读到的固件版本都是真信息。
            // 「版本太低导致拒绝配对」这种情况尤其要让用户看见具体号，
            // 否则界面上只剩一句含糊的「不支持」。
            if let fw = self.runner.lastFirmwareText {
                self.firmwareVersion = fw
                self.persistFirmware(fw)
                let s = self.firmwareSupport
                self.append("🧩 泵固件版本：\(fw) —— \(s.ok ? "支持" : "不支持（\(s.text)）")")
            }
        }
    }

    /// 输注入口。先过安全闸门，再决定：直接拒绝 / 弹长按确认页 / 放行执行。
    /// UI 上所有"打大剂量"的按钮都应该调这个，不要绕过它去调 executeBolus。
    /// 输注入口。设置页的方波卡片与大剂量输入页都走这里，
    /// 好处是安全闸门、审计、确认页只有一份实现。
    /// - Parameters:
    ///   - inputUnits: 剂量；nil = 用大剂量输入框里的值。
    ///   - extendedMinutes: 非 nil = 方波，值为时长（分钟）。
    func sendBolus(units inputUnits: Double? = nil, extendedMinutes: Int? = nil) {
        guard !busy else { return }
        guard !pairedDevice.isEmpty, !pairedPassword.isEmpty else {
            append("⚠️ 请先配对（未保存设备/密码）")
            return
        }
        guard let units = inputUnits ?? Double(bolusUnits), units > 0 else {
            append("⚠️ 大剂量数值无效")
            return
        }
        // 上一条还在推的时候再发，会变成两条叠加 —— 泵不接受并发 bolus，
        // 但两条命令前后脚到达就是两次真实输注。先停再发。
        if let d = bolusDelivery {
            append(String(format: "⚠️ 上一条还在推（剩 %.0f 秒）。要改剂量请先点「停止输注」。",
                          d.remaining(at: Date())))
            statusLine = "正在输注中"
            return
        }

        // 方波：时长只做上下界校验（1…480 分钟），不要求 30 的整数倍 ——
        // 泵侧按 pumpTime 自己分摊，AAPS 也没有粒度限制。
        var extended: Int? = nil
        if let raw = extendedMinutes {
            guard Self.extendedMinutesRange.contains(raw) else {
                append("⚠️ 方波时长超出范围：\(raw) 分钟（可用 1…480）")
                return
            }
            extended = raw
        }

        let req = BolusRequest(units: units,
                               reservoirUnits: reservoirUnits,
                               reservoirAge: reservoirReadAt.map { Date().timeIntervalSince($0) },
                               pumpIsRunning: pumpIsRunning,
                               pumpMaxBolus: pumpConfig.maxBolus)
        let verdict = safety.evaluate(req)
        let kindText = extended.map { "（方波 \($0 / 60) 小时）" } ?? ""
        audit.record(.bolusRequested, units: units, outcome: .pending,
                     serialNumber: serialNumber, note: verdict.shortDescription + kindText)

        switch verdict {
        case .deny(let reason):
            blockReason = reason
            statusLine = "已阻止"
            append("🛑 输注已阻止：\(reason)")
            audit.record(.bolusBlocked, units: units, outcome: .denied,
                         serialNumber: serialNumber, note: reason)

        case .confirm(let reason):
            pendingReason = reason
            pendingBolus = units
            pendingExtendedMinutes = extended
            statusLine = "等待确认 \(units) U"
            append("⏸ 等待确认：\(units) U\(extended.map { " · 方波 \($0) 分钟" } ?? "") — \(reason)")

        case .allow:
            if let m = extended {
                executeExtendedBolus(units: units, minutes: m)
            } else {
                executeBolus(units: units)
            }
        }
    }

    /// 确认页长按通过后调用。
    func confirmBolus() {
        guard let units = pendingBolus else { return }
        let extended = pendingExtendedMinutes
        pendingBolus = nil
        pendingExtendedMinutes = nil
        // 确认期间状态可能已经变了（另一次输注刚完成、余量被别处用掉）。
        // 不复核的话，双击或慢速重复提交就能绕过间隔限制。
        let recheck = safety.evaluate(BolusRequest(units: units,
                                                   reservoirUnits: reservoirUnits,
                                                   reservoirAge: reservoirReadAt.map { Date().timeIntervalSince($0) },
                                                   pumpIsRunning: pumpIsRunning,
                                                   pumpMaxBolus: pumpConfig.maxBolus))
        if case .deny(let reason) = recheck {
            blockReason = reason
            append("🛑 确认时复核未通过：\(reason)")
            audit.record(.bolusBlocked, units: units, outcome: .denied,
                         serialNumber: serialNumber, note: "recheck: \(reason)")
            return
        }
        audit.record(.bolusConfirmed, units: units, serialNumber: serialNumber)
        if let m = extended {
            executeExtendedBolus(units: units, minutes: m)
        } else {
            executeBolus(units: units)
        }
    }

    /// 确认页取消。
    func cancelBolus() {
        // 长按确认后 sheet 关闭也会触发这里的 binding set(false)，
        // 此时 pendingBolus 已被 confirmBolus 清空 —— 不能误记一条"已取消"。
        guard pendingBolus != nil else { return }
        pendingBolus = nil
        pendingExtendedMinutes = nil
        statusLine = "已取消"
        append("✋ 输注已在确认页取消")
        audit.record(.bolusResult, units: 0, outcome: .denied,
                     serialNumber: serialNumber, note: "cancelled at confirm sheet")
    }

    // MARK: - 大剂量进度与中途停止

    /// 泵 ACK 之后开始跟踪。计划时长 = 总量 × 每单位秒数。
    private func beginTrackingBolus(units: Double) {
        let seconds = max(1, units * Double(pumpConfig.bolusSpeed.secondsPerUnit))
        bolusDelivery = BolusDelivery(units: units, startedAt: Date(), seconds: seconds)
        bolusTick = Date()
        stopBolusTicker()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickBolus() }
        }
        RunLoop.main.add(t, forMode: .common)
        bolusTicker = t
        append(String(format: "⏱️ 预计 %.0f 秒推完（%.1f U/min）。中途想停，点界面上方的「停止输注」。",
                      seconds, units * 60 / seconds))
    }

    private func tickBolus() {
        guard let d = bolusDelivery else { stopBolusTicker(); return }
        bolusTick = Date()
        if d.isFinished(at: Date()) {
            stopBolusTicker()
            bolusDelivery = nil
            append(String(format: "✅ 输注完成：%.2f U", d.units))
            statusLine = String(format: "输注完成 %.2f U", d.units)
        }
    }

    private func stopBolusTicker() {
        bolusTicker?.invalidate()
        bolusTicker = nil
    }

    /// 中途停止输注。
    ///
    /// 走 AAPS `stopBolus` 的同一条路：再发一条 `CmdLargeBasalSet(insulin: 0)`，
    /// 泵收到就停。已给量按时间线性估算，且**从停止命令成功的时刻算**
    /// —— AAPS 的注释写得很明白：the pump did less than counted, never more，
    /// 宁可多记一点，也不要少算成低血糖。
    func stopBolusDelivery() {
        guard let delivery = bolusDelivery, !busy else { return }
        busy = true
        statusLine = "正在停止输注…"
        append(String(format: "=== 请求停止输注（计划 %.2f U）===", delivery.units))

        let cmd = CmdLargeBasalSet(insulin: 0,
                                   secondsPerUnit: pumpConfig.bolusSpeed.secondsPerUnit,
                                   createTime: Int64(Date().timeIntervalSince1970 * 1000),
                                   equilDevice: pairedDevice,
                                   equilPassword: pairedPassword)
        runCommandPerConnection(cmd, kind: "停止大剂量") { [weak self] outcome in
            guard let self else { return }
            // 带 completion 时 runCommandPerConnection 不会自己调 handle，
            // busy 就得在这里放开 —— 否则整页按钮一直灰着。
            self.handle(outcome, kind: "停止大剂量")
            switch outcome {
            case .success:
                let now = Date()
                let delivered = delivery.delivered(at: now)
                self.stopBolusTicker()
                self.bolusDelivery = nil
                self.lastBolus = BolusRecord(units: delivered, at: now)
                self.lastDataTime = now
                self.audit.record(.bolusResult, units: delivered, outcome: .ok,
                                  serialNumber: self.serialNumber,
                                  note: String(format: "stopped by user, planned %.2f U", delivery.units))
                self.append(String(format: "✋ 已停止：计划 %.2f U，已给约 %.2f U（按时间估算）",
                                   delivery.units, delivered))
                self.statusLine = String(format: "已停止（约 %.2f / %.2f U）", delivered, delivery.units)
                // 余量、运行状态都可能已经变了，让泵自己说一遍。
                self.scheduleReservoirRefresh(reason: "停止大剂量后回读余量")

            case .failure(let msg):
                // 没停成，泵一定还在推。这句必须说死，不能让用户以为停了。
                self.append("❌ 停止失败：\(msg)。泵可能仍在推注，请再点一次，或直接断开连接。")
                self.statusLine = "停止失败，泵仍在推注"
                self.audit.record(.bolusResult, units: 0, outcome: .failed,
                                  serialNumber: self.serialNumber,
                                  note: "stop request failed: \(msg)")
            }
        }
    }

    /// 真正下发。只有过了闸门才能走到这里。
    private func executeBolus(units: Double) {
        busy = true
        statusLine = "输注 \(units) U…"
        append("=== 输注开始：\(units) U（\(pumpConfig.bolusSpeed.label)）===")
        let cmd = CmdLargeBasalSet(insulin: units,
                                   secondsPerUnit: pumpConfig.bolusSpeed.secondsPerUnit,
                                   createTime: Int64(Date().timeIntervalSince1970 * 1000),
                                   equilDevice: pairedDevice,
                                   equilPassword: pairedPassword)
        // step / stepTime 是这条命令里唯一有物理含义的两个数，打出来便于对账：
        // 0.5 U @ 1.5 U/min 应该是 step=80、stepTime=20。
        append("   step=\(cmd.step)（1/160 U） stepTime=\(cmd.stepTime) 秒")
        // 按命令连接（AAPS 模型）：泵约 11 秒后自动断开，因此
        // 不依赖常驻看门狗连接。
        runCommandPerConnection(cmd, kind: "大剂量") { [weak self] outcome in
            guard let self else { return }
            self.handle(outcome, kind: "大剂量")
            switch outcome {
            case .success:
                // 只有泵真的接受了才记账 —— 失败的命令不占额度，
                // 否则一次超时就把用户锁在门外。
                self.safety.recordBolus(units: units)
                self.audit.record(.bolusResult, units: units, outcome: .ok,
                                  serialNumber: self.serialNumber, note: "accepted by pump")
                // 这里**不做** `reservoirUnits -= 剂量`：泵只报整数单位，本地相减
                // 会让软件显示的余量逐渐多于泵上真实值。改成让泵自己说 ——
                // 泵在输注命令后约 11 秒断开连接，断开后回读一次并覆盖。
                self.scheduleReservoirRefresh(reason: "大剂量后回读余量")
                self.lastBolus = BolusRecord(units: units, at: Date())
                self.lastDataTime = Date()
                // 命令已被接受，泵从此刻开始按 stepTime 推 —— 进入可停止状态。
                self.beginTrackingBolus(units: units)
            case .failure(let msg):
                self.audit.record(.bolusResult, units: units, outcome: .failed,
                                  serialNumber: self.serialNumber, note: msg)
            }
        }
    }

    // MARK: - 方波（延长波）大剂量

    /// 下发方波：总量 units，在 minutes 分钟内匀速推完（泵侧自己按时长分摊，
    /// 不是手机端拆成多次小剂量 —— 那样会变成几十条命令，中途断连就断流）。
    private func executeExtendedBolus(units: Double, minutes: Int) {
        busy = true
        statusLine = "方波 \(units) U / \(minutes) 分钟…"
        append("=== 方波开始：\(units) U over \(minutes) 分钟（\(String(format: "%.2f", units * 60 / Double(minutes))) U/h）===")
        let cmd = CmdExtendedBolusSet(insulin: units,
                                      durationMinutes: minutes,
                                      cancel: false,
                                      createTime: Int64(Date().timeIntervalSince1970 * 1000),
                                      equilDevice: pairedDevice,
                                      equilPassword: pairedPassword)
        append("   step=\(cmd.step)（1/160 U） pumpTime=\(cmd.pumpTime) 秒")
        runCommandPerConnection(cmd, kind: "方波") { [weak self] outcome in
            guard let self else { return }
            self.handle(outcome, kind: "方波")
            switch outcome {
            case .success:
                self.safety.recordBolus(units: units)
                self.audit.record(.bolusResult, units: units, outcome: .ok,
                                  serialNumber: self.serialNumber,
                                  note: "方波 accepted by pump, \(minutes) min")
                self.extendedBolusUnits = units
                self.extendedBolusEnd = Date().addingTimeInterval(Double(minutes) * 60)
                self.scheduleReservoirRefresh(reason: "方波后回读余量")
                self.lastDataTime = Date()
            case .failure(let msg):
                self.audit.record(.bolusResult, units: units, outcome: .failed,
                                  serialNumber: self.serialNumber, note: "方波: " + msg)
            }
        }
    }

    /// 取消正在跑/排队的方波。泵侧用同一条命令、剂量 0、时长 0 表示取消。
    func cancelExtendedBolus() {
        guard !busy else { return }
        busy = true
        statusLine = "取消方波…"
        append("=== 取消方波 ===")
        let cmd = CmdExtendedBolusSet(insulin: 0,
                                      durationMinutes: 0,
                                      cancel: true,
                                      createTime: Int64(Date().timeIntervalSince1970 * 1000),
                                      equilDevice: pairedDevice,
                                      equilPassword: pairedPassword)
        runCommandPerConnection(cmd, kind: "取消方波") { [weak self] outcome in
            guard let self else { return }
            self.handle(outcome, kind: "取消方波")
            if case .success = outcome {
                self.extendedBolusEnd = nil
                self.extendedBolusUnits = 0
                self.scheduleReservoirRefresh(reason: "取消方波后回读余量")
            }
        }
    }

    // MARK: - 排气 / 填充（与 AAPS EquilWizardViewModel.fillLoop 一致）
    //
    //  按步（EQUIL_STEP_FILL=160）推进推杆（CmdStepSet），然后测阻力（CmdResistanceGet）。
    //  阻力达到阈值（SN 首字符 ∈ {0,1,3,A,D} → 500，否则 220）说明推杆已到位 → 可输注。
    //
    //  连接策略与 AAPS 相同：整轮排气跑在**同一条 BLE 连接**上，
    //  CmdStepSet → CmdResistanceGet → CmdStepSet → …，pumpReqIndex 全程递增。
    //  早先每条命令都要 connectForCommand()（断开、重连、重新协商 AES），
    //  一次排气要做几十次握手，这才是「一两分钟」的真正原因 ——
    //  不是步进量（160 与 AAPS 的 EQUIL_STEP_FILL 完全一致）。
    private let primeStepFill = 160
    private let primeStepMax = 32000
    private var primeStepTotal = 0

    /// SN 首字符 ∈ {0,1,3,A,D} → 500（旧泵），否则 220（AAPS getResistanceThreshold）。
    private var resistanceThreshold: Int {
        let first = serialNumber.uppercased().first
        let old: Set<Character> = ["0","1","3","A","D"]
        if let c = first, old.contains(c) { return 500 }
        return 220
    }

    /// 进入配对 / 换敷贴流程时调用：换了储药器或敷贴，排气必须重来一遍。
    func resetPrimeState() {
        primeCompleted = false
        primeStepTotal = 0
        statusLine = "尚未开始排气"
    }

    func startPrime() {
        guard !busy else { return }
        guard !pairedDevice.isEmpty, !pairedPassword.isEmpty else {
            append("⚠️ 请先配对（未保存设备/密码）")
            return
        }
        busy = true
        primeStepTotal = 0
        statusLine = "排气开始…"
        append("=== 排气开始（阻力阈值=\(resistanceThreshold)）===")
        primeMoveStep()
    }

    /// 第 1 步：推进推杆（CmdStepSet 160）。首轮新建连接，之后复用连接 + 会话。
    private func primeMoveStep() {
        let cmd = CmdStepSet(sendConfig: false, step: primeStepFill,
                             createTime: Int64(Date().timeIntervalSince1970 * 1000),
                             equilDevice: pairedDevice, equilPassword: pairedPassword)
        let done: (EquilCommandRunner.Outcome) -> Void = { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success:
                self.primeStepTotal += self.primeStepFill
                self.append("➡️ 推杆已移动，累计步数=\(self.primeStepTotal)")
                self.statusLine = "排气中…"
                self.primeReadResistance()
            case .failure(let msg):
                self.append("❌ 排气步进失败：\(msg)")
                self.append("   推杆可能没动。再点一次「开始排气」会从当前位置重来，不会重复推进。")
                self.statusLine = "排气：步进失败 — \(msg)"
                self.busy = false
                self.ble.onConnected = nil
            }
        }
        // 与 AAPS fillLoop 一致：第 1 步新建连接，之后整轮复用同一条连接 + 同一条会话。
        // 关键不在连接，而在**会话**：泵只在新 GATT 会话的第一个命令里接受
        // 「请求 → 回密钥 → 再发」的协商；同一连接上再走一遍，泵当重放、不回包。
        // 所以复用连接时必须带 runner 保存的 sessionPwd/sessionCode（AAPS 的 preCmd）。
        let canReuse = ble.isConnected && ble.isReady && runner.hasReusableSession
        if primeStepTotal == 0 || !canReuse {
            runCommandPerConnection(cmd, kind: "排气步进", timeout: 60, completion: done)
        } else {
            runCommandOnLiveConnection(cmd, kind: "排气步进", timeout: 60, completion: done)
        }
    }

    /// 在同一条已建立的连接上直接跑下一条命令（不重连、不重置报文序号）。
    /// AAPS `fillLoop` 就是这样连着发的：CmdStepSet → CmdResistanceGet → CmdStepSet …
    /// 连接已断或传输未就绪则退回 `runCommandPerConnection`（重连 + 序号归零）。
    private func runCommandOnLiveConnection(_ cmd: EquilCommandDriving, kind: String,
                                            timeout: TimeInterval,
                                            completion: @escaping (EquilCommandRunner.Outcome) -> Void) {
        guard ble.isConnected, ble.isReady, runner.hasReusableSession else {
            // 连接没了，或者连接还在但没有可复用的会话凭据（上一条失败过）：
            // 都不该在旧连接上重走握手，直接刷新成新连接。
            append("🔌 没有可复用的会话 — 重新连接（\(kind)）")
            runCommandPerConnection(cmd, kind: kind, timeout: timeout, completion: completion)
            return
        }
        ble.pauseWatchdog()
        // AAPS 的 fillLoop 两条命令之间没有 sleep。这里只留 120 ms，
        // 让上一条命令最后一个包的 didWriteValueFor 回调走完，避免写队列交叉。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.ble.isConnected, self.ble.isReady, self.runner.hasReusableSession else {
                    // 还没发出去连接就断了：这条命令等于没执行，重连重发完全安全。
                    self.append("🔌 连接在命令间隔中断开 — 重连后重发（\(kind)）")
                    self.runCommandPerConnection(cmd, kind: kind, timeout: timeout, completion: completion)
                    return
                }
                self.runner.run(command: cmd, timeout: timeout,
                                resetState: false, reuseSession: true) { outcome in
                    completion(outcome)
                }
            }
        }
    }

    /// 第 2 步：测阻力（CmdResistanceGet）。enacted=true → 推杆已到位。
    ///
    /// 阻力查询是**只读**命令，失败了重做没有副作用，所以允许自动重试一次；
    /// 重试会重新建连接（新会话、序号归零）。
    private func primeReadResistance(retryLeft: Int = 1, forceFresh: Bool = false) {
        let cmd = CmdResistanceGet(threshold: resistanceThreshold,
                                   createTime: Int64(Date().timeIntervalSince1970 * 1000),
                                   equilDevice: pairedDevice, equilPassword: pairedPassword)
        let done: (EquilCommandRunner.Outcome) -> Void = { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success(let enacted):
                self.applyPrimeResistance(enacted)
            case .failure(let msg):
                guard retryLeft > 0 else {
                    self.append("❌ 阻力检测失败：\(msg)")
                    self.statusLine = "排气：阻力检测失败 — \(msg)"
                    self.busy = false
                    self.ble.onConnected = nil
                    return
                }
                self.append("↻ 阻力检测没有回包（\(msg)）— 重连后再试一次")
                self.statusLine = "排气：重连重试…"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.primeReadResistance(retryLeft: retryLeft - 1, forceFresh: true)
                }
            }
        }
        // 阻力查询是只读的，失败重试无副作用。
        // 连接还活着、会话凭据也在，就跟在步进命令后面直接发（AAPS fillLoop 同序）；
        // 断了、没凭据或要重试时才新建连接。
        if !forceFresh && ble.isConnected && ble.isReady && runner.hasReusableSession {
            runCommandOnLiveConnection(cmd, kind: "阻力检测", timeout: 25, completion: done)
        } else {
            runCommandPerConnection(cmd,
                                    kind: forceFresh ? "阻力检测(重试)" : "阻力检测",
                                    timeout: 25,
                                    completion: done)
        }
    }

    /// 阻力结果的统一处理：到位就收尾，没到位就再推 160 步。
    private func applyPrimeResistance(_ enacted: Bool) {
        if enacted {
            append("✅ 推杆已到位 — 排气完成（步数=\(primeStepTotal)），可以输注大剂量了")
            statusLine = "排气完成 — 可进入下一步"
            primeCompleted = true
            busy = false
            ble.onConnected = nil
            // 排气会实实在在消耗药量，且只有泵知道消耗了多少。
            scheduleReservoirRefresh(reason: "排气后回读余量")
        } else if primeStepTotal > primeStepMax {
            append("⚠️ 超过最大步数（\(primeStepTotal)）— 请更换储药器")
            statusLine = "排气：超过最大步数"
            busy = false
            ble.onConnected = nil
        } else {
            append("↻ 推杆尚未到位 — 继续…")
            primeMoveStep()
        }
    }

    // MARK: - 运行模式（AAPS EquilPairConfirmFragment 的最后一步）
    //
    //  AAPS 配对的最后一步是 CmdModelSet(RUN=1) — 这才会让泵
    //  进入可接受大剂量的状态。缺少这步，泵会静默丢弃大剂量 Msg2。
    //  配对后可手动触发。

    /// 将泵切换到 RUN 模式（CmdModelSet mode=1）。
    ///
    /// 成功后就地把本机状态改成 RUN：以前只有「查询运行模式」才会更新，
    /// 点完按钮界面仍显示「—」、大剂量按钮也仍然禁用，看着像没生效。
    ///
    /// - Parameter resetTotal: 向导里的初始化/换敷贴传 true —— 新敷贴意味着新的起始量，
    ///   否则「总输送量」会把上一贴的消耗一起算进去。概览页的「恢复输注」用默认 false。
    func setRunMode(resetTotal: Bool = false, completion: ((Bool) -> Void)? = nil) {
        guard !busy else { return }
        guard !pairedDevice.isEmpty, !pairedPassword.isEmpty else {
            append("⚠️ 请先配对（未保存设备/密码）")
            completion?(false)
            return
        }
        busy = true
        statusLine = "运行模式 → 运行中…"
        append("=== 运行模式 → RUN（CmdModelSet mode=1）===")
        let cmd = CmdModelSet(mode: 1,
                              createTime: Int64(Date().timeIntervalSince1970 * 1000),
                              equilDevice: pairedDevice, equilPassword: pairedPassword)
        runCommandPerConnection(cmd, kind: "切换运行中") { [weak self] outcome in
            guard let self else { return }
            self.handle(outcome, kind: "切换运行中")
            var ok = false
            if case .success = outcome {
                ok = true
                self.runMode = .run
                self.pumpIsRunning = true
                self.activationCompleted = true
                if resetTotal { self.resetTotalDelivered() }
                self.lastDataTime = Date()
                self.statusLine = "运行模式：运行中"
                self.persistIdentity()   // 记下"已初始化"，重启后不再显示未完成
                self.audit.record(.runModeChange, outcome: .ok,
                                  serialNumber: self.serialNumber, note: "mode=1")
            }
            completion?(ok)
        }
    }

    /// 查询泵当前运行模式（诊断用）。
    /// 查询运行模式。
    ///
    /// - Parameters:
    ///   - keepingBusy: 批量流程（`refreshStatus`）里由外层持有 `busy`，这里不再自己置位/放开。
    ///   - reuse: 是否复用上一条命令留下的会话凭据（同一次连接里连发时用）。
    ///   - completion: 命令结束（成功或失败）时回调一次，供串行链推进。
    func queryRunningMode(keepingBusy: Bool = false,
                          reuse: Bool = true,
                          completion: (() -> Void)? = nil) {
        if !keepingBusy {
            guard !busy else { completion?(); return }
        }
        guard !pairedDevice.isEmpty, !pairedPassword.isEmpty else {
            append("⚠️ 请先配对（未保存设备/密码）")
            completion?()
            return
        }
        if !keepingBusy { busy = true }
        statusLine = "查询运行模式…"
        append("=== 查询运行模式 ===")
        let cmd = CmdRunningModeGet(createTime: Int64(Date().timeIntervalSince1970 * 1000),
                                    equilDevice: pairedDevice, equilPassword: pairedPassword)
        let done: (EquilCommandRunner.Outcome) -> Void = { [weak self] outcome in
            guard let self else { completion?(); return }
            self.releaseBusy()   // 单发时放开；批量时被 batchDepth 挡住
            self.handle(outcome, kind: "查询运行模式")
            if case .success = outcome {
                // mode: 0=SUSPEND, 1=RUN, 2=STOP
                self.pumpIsRunning = (cmd.mode == 1)
                switch cmd.mode {
                case 1:  self.runMode = .run
                case 0:  self.runMode = .suspend
                case 2:  self.runMode = .stop
                default: self.runMode = .unknown
                }
                self.lastDataTime = Date()
                self.append("运行模式：\(self.runMode.rawValue)")
            } else {
                // 查不到就当作"未确认"，闸门会要求二次确认而不是静默放行
                self.pumpIsRunning = nil
                self.runMode = .unknown
            }
            completion?()
        }
        if reuse {
            runCommandOnLiveConnection(cmd, kind: "查询运行模式", timeout: 30, completion: done)
        } else {
            runCommandPerConnection(cmd, kind: "查询运行模式", completion: done)
        }
    }

    // MARK: - SUSPEND / STOP (CmdModelSet mode=0 / mode=2)

    /// 暂停输注（CmdModelSet mode=0 = SUSPEND）。
    func suspendPump() {
        runModelSet(mode: 0, label: "SUSPEND（暂停输注）")
    }

    /// 停止泵（CmdModelSet mode=2 = STOP）。
    func stopPump() {
        runModelSet(mode: 2, label: "STOP（停止）")
    }

    private func runModelSet(mode: Int, label: String) {
        guard !busy else { return }
        guard !pairedDevice.isEmpty, !pairedPassword.isEmpty else {
            append("⚠️ 请先配对（未保存设备/密码）")
            return
        }
        busy = true
        statusLine = "运行模式 → \(label)…"
        append("=== 运行模式 → \(label)（CmdModelSet mode=\(mode)）===")
        let cmd = CmdModelSet(mode: mode,
                              createTime: Int64(Date().timeIntervalSince1970 * 1000),
                              equilDevice: pairedDevice, equilPassword: pairedPassword)
        runCommandPerConnection(cmd, kind: label) { [weak self] outcome in
            guard let self else { return }
            self.handle(outcome, kind: label)
            if case .success = outcome {
                self.pumpIsRunning = (mode == 1)
                switch mode {
                case 1:  self.runMode = .run
                case 0:  self.runMode = .suspend
                case 2:  self.runMode = .stop
                default: self.runMode = .unknown
                }
                self.lastDataTime = Date()
                // AAPS 的 isActivationCompleted 以 RUN 成功为准：泵不在 RUN 时
                // 大剂量会被静默丢弃，所以只有 RUN 过才算"真的能用了"。
                if mode == 1 { self.activationCompleted = true }
                self.audit.record(.runModeChange, outcome: .ok,
                                  serialNumber: self.serialNumber, note: "mode=\(mode)")
            }
        }
    }

    // MARK: - 固件版本（CmdDevicesGet）

    /// 固件版本是否达标。规则照抄 AAPS 的 `CmdDevicesOldGet.isSupport(SN)`：
    /// **只有 SN 首字符是 0/1/3/A/D 的老批次**才强制 ≥5.3，其余批次不看版本号。
    /// 这一点很容易被误传成「所有泵都必须 5.3 以上」，实际不是。
    var firmwareSupport: (ok: Bool, text: String) {
        guard let fvText = firmwareVersion, let fv = Float(fvText) else {
            return (true, "未读取")
        }
        let first = serialNumber.uppercased().first
        let needsCheck: Set<Character> = ["0", "1", "3", "A", "D"]
        if let first, needsCheck.contains(first), fv < EquilConst.EQUIL_SUPPORT_LEVEL {
            return (false, "\(fvText) < \(EquilConst.EQUIL_SUPPORT_LEVEL)")
        }
        return (true, "\(fvText) 可用")
    }

    /// 已配对状态下读一次设备信息，取固件版本。
    /// 与配对流程第一步的 `CmdDevicesOldGet` 读的是同一个字段，
    /// 区别是这条走标准 AES 握手（port 0000），不需要重新配对。
    func queryFirmware() {
        guard !busy else { return }
        guard !pairedDevice.isEmpty, !pairedPassword.isEmpty else {
            append("⚠️ 请先配对（未保存设备/密码）")
            return
        }
        busy = true
        statusLine = "读取固件版本…"
        append("=== 读取设备信息（CmdDevicesGet）===")
        let cmd = CmdDevicesGet(createTime: Int64(Date().timeIntervalSince1970 * 1000),
                                equilDevice: pairedDevice,
                                equilPassword: pairedPassword)
        runCommandPerConnection(cmd, kind: "设备信息") { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success:
                if cmd.firmwareVersionText.isEmpty {
                    self.append("⚠️ 命令成功，但回包里没取到固件版本字段（载荷不足 20 字节）")
                    self.statusLine = "固件版本：读不到"
                } else {
                    self.firmwareVersion = cmd.firmwareVersionText
                    self.persistFirmware(cmd.firmwareVersionText)
                    let s = self.firmwareSupport
                    self.append("🧩 固件版本 \(cmd.firmwareVersionText) — \(s.text)（\(s.ok ? "支持" : "不支持")）")
                    self.statusLine = "固件 \(cmd.firmwareVersionText)"
                }
            case .failure(let msg):
                self.append("❌ 设备信息读取失败：\(msg)")
                self.statusLine = "固件版本：失败 — \(msg)"
            }
            self.busy = false
            self.ble.onConnected = nil
        }
    }

    /// 固件版本落盘。泵不会自己升级，读到一次就一直有效。
    func persistFirmware(_ fv: String) {
        UserDefaults.standard.set(fv, forKey: IdentityKeys.firmware)
    }

    // MARK: - 储药器状态（CmdInsulinGet）

    /// 查询储药器中剩余的胰岛素（U）。
    func queryInsulin() {
        guard !busy else { return }
        guard !pairedDevice.isEmpty, !pairedPassword.isEmpty else {
            append("⚠️ 请先配对（未保存设备/密码）")
            return
        }
        busy = true
        statusLine = "查询储药器…"
        append("=== 查询储药器（CmdInsulinGet）===")
        let cmd = CmdInsulinGet(createTime: Int64(Date().timeIntervalSince1970 * 1000),
                                equilDevice: pairedDevice, equilPassword: pairedPassword)
        runCommandPerConnection(cmd, kind: "储药器") { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success:
                self.append("💧 泵内余量：\(cmd.insulin) U")
                self.statusLine = "余量 \(cmd.insulin) U"
                // 余量是闸门判断的关键输入：读到就存下来，输注时用它算残留
                if cmd.insulin >= 0 {
                    self.recordReservoirReading(cmd.insulin)
                    self.audit.record(.reservoirQuery, units: Double(cmd.insulin),
                                      outcome: .ok, serialNumber: self.serialNumber)
                }
            case .failure(let msg):
                self.append("❌ 储药器查询失败：\(msg)")
                self.statusLine = "储药器：失败 — \(msg)"
            }
            self.busy = false
            self.ble.onConnected = nil
        }
    }

    // MARK: - 余量的"唯一真相"策略
    //
    //  泵的余量字段是**整数单位**（CmdInsulinGet data[6] / CmdHistoryGet data[13]）。
    //  软件能做的只有两件事：
    //    1. 读数一律以泵为准，不在本地按剂量做减法；
    //    2. 凡是会让药量变化的事件（大剂量、排气/填充）之后，主动回读一次。
    //  这样最坏情况是"上次回读以来的消耗看不到"，而不是"越用越多"。

    private var reservoirRefreshToken = 0

    /// 记一次泵回读的余量，并在「本次敷贴还没记过起始量」时把它记为起始量。
    ///
    /// 「总输送量」= 起始量 − 当前余量，与 AAPS `EquilOverviewViewModel` 同口径。
    /// 两个数都是泵回报的**整数单位**，所以这个值只能是近似值；起始量在每次
    /// 初始化 / 换敷贴（向导里的 RUN 成功）时清空，由之后第一条读数重新接上。
    private func recordReservoirReading(_ units: Int) {
        guard units >= 0 else { return }
        reservoirUnits = units
        reservoirReadAt = Date()
        if startInsulin == nil {
            startInsulin = units
            UserDefaults.standard.set(units, forKey: IdentityKeys.startInsulin)
        }
    }

    /// 起始量 − 当前余量。任一边未知就返回 nil（界面显示「-」，不拿 0 冒充）。
    var totalDeliveredUnits: Int? {
        guard let start = startInsulin, let now = reservoirUnits else { return nil }
        return max(0, start - now)
    }

    /// 新敷贴 / 新储药器开始：清掉起始量，等下一次回读重新接上。
    private func resetTotalDelivered() {
        startInsulin = nil
        UserDefaults.standard.removeObject(forKey: IdentityKeys.startInsulin)
    }

    /// 在消耗药量的事件之后延迟回读泵内余量。
    ///
    /// 为什么延迟：泵收到输注命令后约 11 秒才断开 BLE，命令刚结束就重连
    /// 会撞在泵还没释放的链路上。等它自己断开再连，成功率最高。
    /// 若此刻用户正在执行别的命令（busy），退避重试最多 3 次，不打断用户操作。
    func scheduleReservoirRefresh(after seconds: Double = 12, reason: String = "回读余量") {
        guard isPaired else { return }
        reservoirRefreshToken += 1
        let token = reservoirRefreshToken
        Task { @MainActor in
            var delay = seconds
            for attempt in 1...3 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard token == self.reservoirRefreshToken else { return }
                guard self.isPaired else { return }
                if !self.busy {
                    self.append("🔄 \(reason)（第 \(attempt) 次尝试）")
                    self.queryInsulin()
                    return
                }
                self.append("⏳ \(reason)：当前有命令在执行，稍后重试")
                delay = 15
            }
        }
    }

    /// 余量读数距今多久（给界面显示用）。
    var reservoirAgeShort: String? {
        guard let t = reservoirReadAt else { return nil }
        let s = Int(Date().timeIntervalSince(t))
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(s / 60) 分钟前" }
        return "\(s / 3600) 小时前"
    }

    /// 超过 20 分钟没回读，就认为这个数字只能当参考。
    var reservoirIsStale: Bool {
        guard let t = reservoirReadAt else { return true }
        return Date().timeIntervalSince(t) > 20 * 60
    }

    // MARK: - 历史 / 状态（CmdHistoryGet）

    /// 查询泵当前状态（电池、储药器、时间、上次剂量）。
    /// 查询泵状态（CmdHistoryGet 的序号 0）：电池、余量、当前速率。
    ///
    /// - Parameters:
    ///   - keepingBusy: 批量流程里由外层持有 `busy`。
    ///   - reuse: 复用同一次连接的会话凭据。
    ///   - completion: 结束回调（串行链推进）。
    func queryHistory(keepingBusy: Bool = false,
                      reuse: Bool = true,
                      completion: (() -> Void)? = nil) {
        if !keepingBusy {
            guard !busy else { completion?(); return }
        }
        guard !pairedDevice.isEmpty, !pairedPassword.isEmpty else {
            append("⚠️ 请先配对（未保存设备/密码）")
            completion?()
            return
        }
        if !keepingBusy { busy = true }
        statusLine = "查询状态/历史…"
        append("=== 查询历史/状态（CmdHistoryGet）===")
        let cmd = CmdHistoryGet(currentIndex: 0,
                                createTime: Int64(Date().timeIntervalSince1970 * 1000),
                                equilDevice: pairedDevice, equilPassword: pairedPassword)
        let done: (EquilCommandRunner.Outcome) -> Void = { [weak self] outcome in
            guard let self else { completion?(); return }
            switch outcome {
            case .success:
                self.append("🔋 电池=\(cmd.battery)%  💧储药器=\(cmd.medicine)  速率=\(cmd.rate)  时间=\(cmd.ts)  序号=\(cmd.recordIndex)")
                self.statusLine = "电池 \(cmd.battery)% · 储药器 \(cmd.medicine)"
                // 同步到概览页状态
                self.batteryPercent = cmd.battery
                self.recordReservoirReading(cmd.medicine)
                self.lastDataTime = Date()
            case .failure(let msg):
                self.append("❌ 状态查询失败：\(msg)")
                self.statusLine = "状态：失败 — \(msg)"
            }
            self.releaseBusy()
            self.ble.onConnected = nil
            completion?()
        }
        if reuse {
            runCommandOnLiveConnection(cmd, kind: "状态", timeout: 30, completion: done)
        } else {
            runCommandPerConnection(cmd, kind: "状态", completion: done)
        }
    }

    // MARK: - 启动/回前台的自动连接
    //
    //  以前杀进程再进来，泵的 CBPeripheral 句柄随进程一起没了，`connectForCommand`
    //  只能在「无句柄」分支里退回扫描，而扫描要有人点「运行」才被触发 —— 于是看起来
    //  就是「打开软件不会自己连」。
    //
    //  现在两条路都不用人点：
    //    1. 首次配对/连接时把 peripheral.identifier 落盘（EquilBLEManager.remember）。
    //       iOS 按 UUID 记得这个 peripheral，`retrievePeripherals` 就能拿回句柄，
    //       直接 connect，连扫描都省了。
    //    2. 句柄找不回来（换机、重装、iOS 清过缓存）才退回扫描，并且只认 SN 对得上
    //       的那台，扫到就自动连 —— 绝不自动连陌生泵。

    private var autoConnectPending = false
    private var lastAutoConnectAt: Date?
    private var autoPickAfterScan = false

    /// App 启动、或从后台回到前台时调用。已配对就自己找泵、自己连。
    /// 30 秒节流：来回切前台时不要反复发起 15 秒的连接，把 busy 占死。
    func autoConnectOnLaunch() {
        guard isPaired else { return }
        if let t = lastAutoConnectAt, Date().timeIntervalSince(t) < 30 { return }
        guard !busy else { return }
        lastAutoConnectAt = Date()
        autoConnectPending = true
        statusLine = "正在自动连接泵…"
        append("=== 自动连接（启动 / 回到前台）===")
        waitForBluetoothThenAutoConnect(attempt: 0)
    }

    /// 冷启动时 CBCentralManager 还没回调 state，最多等 10 秒。
    private func waitForBluetoothThenAutoConnect(attempt: Int) {
        guard autoConnectPending else { return }
        if ble.isPoweredOn {
            autoConnectPending = false
            performAutoConnect()
            return
        }
        guard attempt < 20 else {
            autoConnectPending = false
            append("⚠️ 蓝牙 10 秒内未就绪 — 自动连接放弃，可手动点「刷新」重试")
            statusLine = "蓝牙未就绪"
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self?.waitForBluetoothThenAutoConnect(attempt: attempt + 1)
        }
    }

    private func performAutoConnect() {
        guard isPaired, !busy else { return }
        if ble.isConnected, ble.isReady {
            append("🔗 连接还在 — 直接读泵状态")
            refreshStatus()
            return
        }
        if ble.restoreLastPeripheral() {
            append("🔎 用上次的泵标识直接连接（跳过扫描）")
            refreshStatus()
            return
        }
        append("🔎 没有可用的泵标识 — 扫描附近的 Equil 泵")
        statusLine = "自动扫描泵…"
        autoPickAfterScan = true
        startScan()
        // 扫不到就收工，别让扫描一直开着耗电。
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard let self, self.autoPickAfterScan else { return }
            self.autoPickAfterScan = false
            self.stopScan()
            self.append("⚠️ 12 秒内没扫到上次配对的泵 — 请确认泵已开机、在 1 米内、没被泵控制器 占着连接")
            self.statusLine = "未找到泵"
        }
    }

    // MARK: - 泵端历史（逐条读泵内事件库）

    /// 泵内历史，按序号从大到小（最新的在最上面）。
    @Published var pumpHistory: [PumpHistoryRecord] = []
    /// 正在逐条读取。
    @Published var pumpHistoryReading: Bool = false
    /// 读取进度 / 结果，直接显示在历史页。
    @Published var pumpHistoryMessage: String = ""
    /// 这次读到的最新序号（诊断用：泵没有历史时这里是 0）。
    @Published var pumpHistoryNewestIndex: Int = 0
    /// 泵自己的时钟（读历史时泵回报的时间）。
    ///
    /// 泵端历史里的年月日时分秒全部取自泵内 RTC，与手机无关。泵没校过时
    /// （出厂、换电池、复位）RTC 停在 2000-01-01，记录时间就是 2000 年 ——
    /// 用 `syncPumpTime()` 把手机时间写进去，之后新写的记录才准。
    @Published var pumpClock: Date?

    private var pendingHistoryIndices: [Int] = []
    private var collectedHistory: [PumpHistoryRecord] = []
    private var historyStepFailures = 0

    /// 从泵内历史库读最近 `count` 条。
    ///
    /// 泵的历史库是**按绝对序号寻址**的环形表（1…2000，写满回绕），
    /// 每条记录都要单独一条 CmdHistoryGet（端口 0x0505）：
    /// 先读序号 0 拿「当前状态」，它的 `index` 字段就是最新记录序号，
    /// 再从这个序号往回数 `count` 条逐条读。
    ///
    /// AAPS 是在每次连接后自动补读新增部分（最多 20 条/次）；这里没有后台循环，
    /// 改成历史页上手动触发，同样一次最多 20 条，避免长时间占着 BLE。
    func readPumpHistory(count: Int = 20) {
        guard isPaired else {
            pumpHistoryMessage = "未配对"
            return
        }
        guard !busy else { return }
        busy = true
        pumpHistoryReading = true
        pumpHistory = []
        collectedHistory = []
        pendingHistoryIndices = []
        historyStepFailures = 0
        pumpHistoryMessage = "读取最新记录序号…"
        append("=== 读取泵端历史（最多 \(count) 条）===")

        // 兜底：连接超时那条路径不会回调 completion（它只把 busy 置回 false），
        // 不设看门狗的话转圈会一直转。120 秒足够 20 条走完。
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            guard let self, self.pumpHistoryReading else { return }
            self.finishPumpHistory(error: "读取超时（120 秒）— 已读 \(self.collectedHistory.count) 条")
        }

        let probe = CmdHistoryGet(currentIndex: 0,
                                  createTime: Int64(Date().timeIntervalSince1970 * 1000),
                                  equilDevice: pairedDevice, equilPassword: pairedPassword)
        runCommandPerConnection(probe, kind: "历史序号", timeout: 25) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .failure(let msg):
                self.finishPumpHistory(error: "读序号失败：\(msg)")
            case .success:
                let newest = probe.recordIndex
                self.pumpHistoryNewestIndex = newest
                // 序号 0 的这条回包里带泵当前时钟，顺手记下来给「泵时钟」那一栏用。
                self.pumpClock = probe.eventDate
                self.append("🧾 泵报告的最新记录序号 = \(newest)（电池 \(probe.battery)% 余量 \(probe.medicine)，泵时钟 \(probe.ts)）")
                guard newest > 0 else {
                    self.finishPumpHistory(error: "泵返回序号 0 — 没有历史记录，或这台固件不提供")
                    return
                }
                let lower = max(1, newest - count + 1)
                self.pendingHistoryIndices = Array(lower...newest)
                self.pumpHistoryMessage = "0/\(self.pendingHistoryIndices.count)"
                self.readNextPumpHistoryRecord()
            }
        }
    }

    /// 读下一条。连接还在、且上一条留下了会话凭据时直接复用（省掉每轮重连），
    /// 否则新建连接重新协商 —— 与排气同一套复用规则。
    private func readNextPumpHistoryRecord() {
        guard let idx = pendingHistoryIndices.first else {
            finishPumpHistory(error: nil)
            return
        }
        pendingHistoryIndices.removeFirst()
        let cmd = CmdHistoryGet(currentIndex: idx,
                                createTime: Int64(Date().timeIntervalSince1970 * 1000),
                                equilDevice: pairedDevice, equilPassword: pairedPassword)
        let done: (EquilCommandRunner.Outcome) -> Void = { [weak self] outcome in
            self?.handlePumpHistoryStep(cmd: cmd, requested: idx, outcome: outcome)
        }
        if ble.isConnected, ble.isReady, runner.hasReusableSession {
            runCommandOnLiveConnection(cmd, kind: "历史 #\(idx)", timeout: 25, completion: done)
        } else {
            runCommandPerConnection(cmd, kind: "历史 #\(idx)", timeout: 25, completion: done)
        }
    }

    private func handlePumpHistoryStep(cmd: CmdHistoryGet,
                                       requested: Int,
                                       outcome: EquilCommandRunner.Outcome) {
        switch outcome {
        case .success:
            historyStepFailures = 0
            if let date = cmd.eventDate {
                collectedHistory.append(
                    PumpHistoryRecord(index: cmd.recordIndex,
                                      time: date,
                                      battery: cmd.battery,
                                      insulin: cmd.medicine,
                                      rate: Double(cmd.rate) / 160.0,
                                      port: cmd.portCode,
                                      type: cmd.type,
                                      level: cmd.level,
                                      parm: cmd.parm)
                )
            } else {
                append("⚠️ 历史 #\(requested) 回包没有可解析的时间")
            }
        case .failure(let msg):
            historyStepFailures += 1
            append("⚠️ 历史 #\(requested) 读取失败：\(msg)")
            if historyStepFailures >= 3 {
                finishPumpHistory(error: "连续 3 条读取失败，已停止")
                return
            }
        }
        let done = collectedHistory.count
        pumpHistoryMessage = "\(done)/\(done + pendingHistoryIndices.count)"
        readNextPumpHistoryRecord()
    }

    private func finishPumpHistory(error: String?) {
        pumpHistory = collectedHistory.sorted { $0.index > $1.index }
        pumpHistoryReading = false
        releaseBusy()
        ble.onConnected = nil
        if let error {
            pumpHistoryMessage = error
            append("❌ 泵端历史：\(error)")
        } else {
            pumpHistoryMessage = "共 \(pumpHistory.count) 条"
            append("✅ 泵端历史读取完成：\(pumpHistory.count) 条（最新序号 \(pumpHistoryNewestIndex)）")
        }
    }

    /// 刷新：运行模式 → 电池/余量 → 临时基础率。
    ///
    /// 三条命令**共用一次连接**（第一条建连，后两条复用会话凭据，与 AAPS
    /// 一次连接连发多条一致），并且整批只持有一次 `busy`。
    ///
    /// 以前每条命令各自 `busy = true/false`，两条之间还留 400 ms 间隙，
    /// 于是按钮会「灰—亮—灰—亮—灰」闪三次，看着像卡住要等三次刷新。
    /// 现在从建连到读完只灰一次。
    func refreshStatus() {
        guard isPaired else { return }
        guard !busy else { return }
        busy = true
        batchDepth += 1
        statusLine = "刷新中…（运行模式）"
        append("=== 刷新（运行模式 → 电池/余量 → 临时基础率，共用一次连接）===")

        // 看门狗：任何一条命令的回调没回来，也不能把按钮永久锁死。
        let stamp = Date()
        refreshStartedAt = stamp
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            guard let self, self.refreshStartedAt == stamp, self.batchDepth > 0 else { return }
            self.finishRefresh(note: "刷新超时（90 秒）— 已读到部分数据，可再点一次刷新")
        }

        queryRunningMode(keepingBusy: true) { [weak self] in
            guard let self else { return }
            self.statusLine = "刷新中…（电池 / 余量）"
            self.queryHistory(keepingBusy: true) { [weak self] in
                guard let self else { return }
                self.statusLine = "刷新中…（临时基础率）"
                self.queryTempBasal(quiet: true, keepingBusy: true) { [weak self] in
                    self?.finishRefresh()
                }
            }
        }
    }

    private var refreshStartedAt: Date?

    /// 收尾：放开 `busy`，把三项读数拼成一行状态。
    private func finishRefresh(note: String? = nil) {
        guard batchDepth > 0 else { return }
        batchDepth = 0
        refreshStartedAt = nil
        busy = false
        if let note {
            statusLine = note
            append("⚠️ \(note)")
            return
        }
        var parts: [String] = []
        switch runMode {
        case .run:     parts.append("运行中")
        case .suspend: parts.append("已暂停")
        case .stop:    parts.append("已停止")
        case .unknown: parts.append("模式未知")
        }
        if let b = batteryPercent { parts.append("电池 \(b)%") }
        if let u = reservoirUnits { parts.append("余量 \(u) U") }
        if let r = tempBasalRate, let m = tempBasalRemainingMin, m > 0 {
            parts.append(String(format: "临时 %.2f U/h · 剩 %d 分钟", r, m))
        } else {
            parts.append("无临时基础率")
        }
        statusLine = parts.joined(separator: " · ")
        append("✅ 刷新完成：\(statusLine)")
    }

    /// 本地解绑：清除本机保存的设备与密码，并复位所有读数。
    /// 不向泵发送 CmdUnPair —— 该命令尚未移植，泵内可能仍保留配对关系。
    func unpairLocal(note: String = "local unpair only") {
        runner.clearPairing()
        ble.forgetLastPeripheral()   // 解绑后不要再按旧标识自动去连
        pairedDevice = ""
        pairedPassword = ""
        selectedDevice = nil
        pairingState = .idle
        activationCompleted = false
        primeCompleted = false
        runMode = .unknown
        pumpIsRunning = nil
        reservoirUnits = nil
        reservoirReadAt = nil
        batteryPercent = nil
        lastDataTime = nil
        lastBolus = nil
        startInsulin = nil
        tempBasalRate = nil
        tempBasalRemainingMin = nil
        tempBasalUntil = nil
        tempBasalSetAt = nil
        tempBasalPendingVerify = false
        stopTempBasalTicker()
        statusLine = "已解除本机配对"
        append("🔓 已清除本机配对信息（\(note)）")
        persistIdentity()   // 同步清掉 UserDefaults 里的 pairedDevice / pairedPassword
        audit.record(.pairing, outcome: .ok, serialNumber: serialNumber, note: note)
    }

    /// 换储药器第 1 步：让推杆退到限位（CmdInsulinChange，32000 步）。
    ///
    /// 与 AAPS `EquilWizardViewModel.startChangeInsulin()` 同序：成功后本机记成 STOP
    /// （泵确实停了，不记会误导大剂量按钮），并把本次敷贴的起始量清掉 —— 新储药器
    /// 意味着「总输送量」从头算。
    ///
    /// 失败就停在原页：推杆没退回去就装新药，后面排气一定撞限位。
    func retractPlunger(completion: ((Bool) -> Void)? = nil) {
        guard !busy else { return }
        guard !pairedDevice.isEmpty, !pairedPassword.isEmpty else {
            append("⚠️ 请先配对（未保存设备/密码）")
            completion?(false)
            return
        }
        busy = true
        statusLine = "推杆退回中…（最长 30 秒）"
        append("=== 换储药器：推杆退回（CmdInsulinChange, 32000 步）===")
        let cmd = CmdInsulinChange(createTime: Int64(Date().timeIntervalSince1970 * 1000),
                                   equilDevice: pairedDevice, equilPassword: pairedPassword)
        runCommandPerConnection(cmd, kind: "推杆退回") { [weak self] outcome in
            guard let self else { return }
            self.handle(outcome, kind: "推杆退回")
            var ok = false
            switch outcome {
            case .success:
                ok = true
                self.append("✅ 推杆已退回到底（status=\(cmd.status)）")
                self.runMode = .stop
                self.pumpIsRunning = false
                // 泵现在是停止状态、储药器也换了：初始化标记与累计量都归零，
                // 概览页的横幅才不会说「已就绪」。
                self.activationCompleted = false
                self.resetTotalDelivered()
                self.resetPrimeState()      // 会重置 primeCompleted / 步数，必须在设文案之前
                self.statusLine = "推杆已退回 — 装入新储药器后继续"
                self.persistIdentity()
            case .failure(let msg):
                self.append("❌ 推杆退回失败：\(msg)")
                self.statusLine = "推杆退回失败 — \(msg)"
            }
            self.busy = false
            completion?(ok)
        }
    }

    /// 解绑：推杆先退回底部，再 STOP，最后清本机配对。
    ///
    /// 顺序照抄 AAPS `EquilWizardViewModel.startUnpairDetach()`：
    ///   1. `CmdInsulinChange`（[0x01,0x06]+32000）→ 推杆退到限位；
    ///   2. `CmdModelSet(mode=2)` → STOP；
    ///   3. 清本机 device / password。
    /// 泵联系不上时仍然清本地配对（best-effort），只是提示里说明推杆没退。
    func unpairAndRetract(completion: ((Bool) -> Void)? = nil) {
        guard !busy else { return }
        guard !pairedDevice.isEmpty, !pairedPassword.isEmpty else {
            unpairLocal(note: "本来就没有配对信息")
            completion?(false)
            return
        }
        busy = true
        statusLine = "解绑 1/2：推杆退回中…"
        append("=== 解绑 1/2：推杆退回（CmdInsulinChange, 32000 步）===")
        let cmd = CmdInsulinChange(createTime: Int64(Date().timeIntervalSince1970 * 1000),
                                   equilDevice: pairedDevice, equilPassword: pairedPassword)
        runCommandPerConnection(cmd, kind: "推杆退回") { [weak self] outcome in
            guard let self else { return }
            self.handle(outcome, kind: "推杆退回")
            var retracted = false
            switch outcome {
            case .success:
                retracted = true
                self.append("✅ 推杆已退回到底（status=\(cmd.status)）")
            case .failure(let msg):
                self.append("⚠️ 推杆退回失败：\(msg) — 仍会尝试停止并清除配对")
            }
            self.stopThenUnpair(retracted: retracted, completion: completion)
        }
    }

    private func stopThenUnpair(retracted: Bool, completion: ((Bool) -> Void)?) {
        busy = true
        statusLine = "解绑 2/2：停止输注…"
        append("=== 解绑 2/2：STOP（CmdModelSet mode=2）===")
        let cmd = CmdModelSet(mode: 2,
                              createTime: Int64(Date().timeIntervalSince1970 * 1000),
                              equilDevice: pairedDevice, equilPassword: pairedPassword)
        runCommandPerConnection(cmd, kind: "解绑停止") { [weak self] outcome in
            guard let self else { return }
            self.handle(outcome, kind: "解绑停止")
            let note = retracted ? "推杆已退回底部，泵已 STOP，清除本机配对"
                                  : "泵未响应，只清除了本机配对（推杆未退回）"
            self.unpairLocal(note: note)
            completion?(retracted)
        }
    }

    // MARK: - 基础率（CmdBasalGet，AAPS 4.0 新增）

    /// 读取泵内基础率。AAPS 概览页「基础率」一栏就来自这条命令。
    func queryBasal() {
        guard !busy else { return }
        guard isPaired else {
            append("⚠️ 请先配对（未保存设备/密码）")
            return
        }
        busy = true
        statusLine = "读取基础率…"
        append("=== 读取基础率（CmdBasalGet）===")
        let cmd = CmdBasalGet(createTime: Int64(Date().timeIntervalSince1970 * 1000),
                              equilDevice: pairedDevice, equilPassword: pairedPassword)
        runCommandPerConnection(cmd, kind: "读取基础率") { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success:
                if let rates = cmd.hourlyRates, !rates.isEmpty {
                    self.baseBasalRate = rates.first
                    let text = rates.prefix(8).map { String(format: "%.3f", $0) }.joined(separator: " / ")
                    self.append("📈 基础率（0 时起，前 8 小时）：\(text) U/h")
                    self.statusLine = "基础率 \(String(format: "%.3f", rates[0])) U/h"
                    self.lastDataTime = Date()
                } else {
                    self.append("⚠️ 泵只回了 ack，没带基础率表 —— 读数保持不变")
                }
            case .failure(let msg):
                self.append("❌ 读取基础率失败：\(msg)")
                self.statusLine = "基础率：失败 — \(msg)"
            }
            self.busy = false
            self.ble.onConnected = nil
        }
    }

    // MARK: - 校时（CmdTimeSet，AAPS 4.0 新增）

    /// 把手机时间写进泵。泵时钟漂移会让历史与剂量时间线错位。
    func syncPumpTime() {
        guard !busy else { return }
        guard isPaired else {
            append("⚠️ 请先配对（未保存设备/密码）")
            return
        }
        busy = true
        statusLine = "正在校时…"
        append("=== 校时（CmdTimeSet）===")
        let cmd = CmdTimeSet(createTime: Int64(Date().timeIntervalSince1970 * 1000),
                             equilDevice: pairedDevice, equilPassword: pairedPassword)
        runCommandPerConnection(cmd, kind: "校时") { [weak self] outcome in
            guard let self else { return }
            self.handle(outcome, kind: "校时")
            if case .success = outcome {
                self.lastDataTime = Date()
                // 泵接受的瞬间泵时钟 ≈ 手机时间；界面立刻反映，不必再读一次历史。
                self.pumpClock = Date()
                self.append("🕒 泵时钟已对齐到手机时间，之后新写入的记录时间才准（旧记录不会改）")
            }
        }
    }

    // MARK: - 临时基础率（CmdTempBasalSet / CmdTempBasalGet）
    //
    //  泵侧的三个事实（对照 AAPS `EquilPumpPlugin.setTempBasalAbsolute`）：
    //    1. 只有 RUN 模式接受临时基础率；STOP / SUSPEND 时泵直接不理这条命令；
    //    2. `CmdTempBasalSet` 的确认包里没有可用状态位 —— AAPS 自己也无条件
    //       置 cmdSuccess，所以「命令发送完成」≠「泵已接受」；
    //    3. 泵回报的是**剩余秒数**，不是设定时长。
    //  所以下发之后必须做两件事：乐观更新界面 + 回读一次纠正，否则概览页的
    //  「临时基础速率」永远停在「-」，看着就像没生效。

    /// 是否已知有临时基础率在跑（用本地状态判断，不需要额外连泵）。
    var tempBasalActive: Bool { tempBasalRate != nil }

    /// 设置临时基础率（速率 U/h + 时长分钟）。
    func setTempBasal() {
        guard !busy else { return }
        guard !pairedDevice.isEmpty, !pairedPassword.isEmpty else {
            append("⚠️ 请先配对（未保存设备/密码）")
            return
        }
        let rateText = tempRate.replacingOccurrences(of: "，", with: ".")
            .replacingOccurrences(of: ",", with: ".")
        guard let rate = Double(rateText), rate > 0,
              let dur = Int(tempDuration), dur > 0 else {
            append("⚠️ 临时基础率无效：速率要 > 0 U/h，时长要 > 0 分钟")
            statusLine = "临时基础率：输入无效"
            return
        }
        // 泵只在 RUN 下接受临时基础率。模式已知且不是 RUN 就先挡住，
        // 免得用户对着一条「发送成功」的日志干等。
        if runMode == .suspend || runMode == .stop {
            append("⚠️ 当前运行模式是「\(runMode.displayName)」，泵不接受临时基础率。请先切到运行中再设。")
            statusLine = "临时基础率：需先切到运行中"
            return
        }
        // 泵不接受「叠加」：已经有一条临时基础率在跑时，AAPS 的做法是先取消再设新的
        // （EquilPumpPlugin.setTempBasalAbsolute → cancelTempBasal(true)）。
        // 这里照做，否则第二条命令会被泵默默丢掉。
        if tempBasalActive {
            append("ℹ️ 已有临时基础率在跑，先取消它再设新的（泵不接受叠加）…")
            cancelTempBasalThenSet(rate: rate, dur: dur)
            return
        }
        sendTempBasalSet(rate: rate, dur: dur)
    }

    /// 真正下发一条新的临时基础率（不含「先取消旧的」这一步）。
    private func sendTempBasalSet(rate: Double, dur: Int) {
        guard !busy else { return }
        busy = true
        statusLine = "临时基础率 \(rate) U/h · \(dur) 分钟…"
        append("=== 设置临时基础率：\(rate) U/h，\(dur) 分钟 ===")
        let cmd = CmdTempBasalSet(insulin: rate, duration: dur,
                                  createTime: Int64(Date().timeIntervalSince1970 * 1000),
                                  equilDevice: pairedDevice, equilPassword: pairedPassword)
        append(String(format: "   下发参数：step=%d（≈%.2f U/h）· pumpTime=%d 秒",
                      cmd.step, rate, cmd.pumpTime))
        runCommandPerConnection(cmd, kind: "Temp basal") { [weak self] outcome in
            guard let self else { return }
            self.handle(outcome, kind: "设置临时基础率")
            switch outcome {
            case .success:
                // 先按「泵已接受」显示，2.5 秒后回读纠正（见 verifyTempBasal）。
                self.applyTempBasal(rate: rate, minutes: dur, at: Date(), pending: true)
                self.append("⏳ 已下发，2.5 秒后回读确认（泵的确认包不带状态位）…")
                self.verifyTempBasal(after: 2.5)
            case .failure(let msg):
                self.statusLine = "临时基础率：失败 — \(msg)"
            }
        }
    }

    /// 取消当前临时基础率（insulin=0 → cancel）。
    func cancelTempBasal() {
        guard !busy else { return }
        guard !pairedDevice.isEmpty, !pairedPassword.isEmpty else {
            append("⚠️ 请先配对（未保存设备/密码）")
            return
        }
        busy = true
        statusLine = "取消临时基础率…"
        append("=== 取消临时基础率 ===")
        let cmd = CmdTempBasalSet(insulin: 0, duration: 0,
                                  createTime: Int64(Date().timeIntervalSince1970 * 1000),
                                  equilDevice: pairedDevice, equilPassword: pairedPassword)
        runCommandPerConnection(cmd, kind: "取消临时基础率") { [weak self] outcome in
            guard let self else { return }
            self.handle(outcome, kind: "取消临时基础率")
            if case .success = outcome {
                self.clearTempBasal()
                self.statusLine = "临时基础率：已取消"
                self.append("⏹️ 已下发取消临时基础率")
            }
        }
    }

    /// 「先把旧 TBR 取消，再设新的」。两条命令各要一次连接，所以中间留 1.5 秒
    /// 让泵收尾；取消失败就中止，不硬着头皮叠加一条。
    private func cancelTempBasalThenSet(rate: Double, dur: Int) {
        guard !busy else { return }
        busy = true
        statusLine = "先取消已有临时基础率…"
        let cmd = CmdTempBasalSet(insulin: 0, duration: 0,
                                  createTime: Int64(Date().timeIntervalSince1970 * 1000),
                                  equilDevice: pairedDevice, equilPassword: pairedPassword)
        runCommandPerConnection(cmd, kind: "取消旧临时基础率") { [weak self] outcome in
            guard let self else { return }
            self.handle(outcome, kind: "取消旧临时基础率")
            switch outcome {
            case .success:
                self.clearTempBasal()
                self.append("⏹️ 旧临时基础率已取消，1.5 秒后下发新的…")
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard !self.busy else {
                        self.append("（新速率未下发：期间有其它命令占用了连接，请重新点「设置」。）")
                        return
                    }
                    self.sendTempBasalSet(rate: rate, dur: dur)
                }
            case .failure(let msg):
                self.append("❌ 旧临时基础率取消失败（\(msg)），为免叠加，新速率没有下发。请先点「查询」确认泵里还有没有 TBR。")
                self.statusLine = "临时基础率：旧值取消失败，已中止"
            }
        }
    }

    /// 查询当前临时基础率。quiet = 下发后的自动回读：不刷状态栏、失败不吓人。
    func queryTempBasal(quiet: Bool = false,
                        keepingBusy: Bool = false,
                        reuse: Bool = true,
                        completion: (() -> Void)? = nil) {
        if !keepingBusy {
            guard !busy else { completion?(); return }
        }
        guard !pairedDevice.isEmpty, !pairedPassword.isEmpty else {
            if !quiet { append("⚠️ 请先配对（未保存设备/密码）") }
            completion?()
            return
        }
        if !keepingBusy { busy = true }
        if !quiet {
            statusLine = "查询临时基础率…"
            append("=== 查询临时基础率（CmdTempBasalGet）===")
        }
        let cmd = CmdTempBasalGet(createTime: Int64(Date().timeIntervalSince1970 * 1000),
                                  equilDevice: pairedDevice, equilPassword: pairedPassword)
        let done: (EquilCommandRunner.Outcome) -> Void = { [weak self] outcome in
            guard let self else { completion?(); return }
            self.releaseBusy()
            self.handle(outcome, kind: "查询临时基础率")
            switch outcome {
            case .success:
                if cmd.step == 0 {
                    let hadLocal = self.tempBasalActive
                    self.clearTempBasal()
                    self.tempBasalPendingVerify = false
                    self.append("⏱️ 泵回报：当前无临时基础率（step=0）")
                    if hadLocal {
                        self.append("⚠️ 泵没有接受刚才那条临时基础率：确认运行模式是 RUN，且泵没有被泵控制器 占用。")
                    }
                    if !quiet { self.statusLine = "临时基础率：无" }
                } else {
                    self.applyTempBasal(rate: cmd.rate,
                                        minutes: cmd.durationMinutes,
                                        at: Date(), pending: false)
                    self.append(String(format: "⏱️ 泵回报：≈%.2f U/h，剩余 %d 分钟（step=%d, %d 秒）",
                                       cmd.rate, cmd.durationMinutes, cmd.step, cmd.time))
                    if !quiet {
                        self.statusLine = String(format: "临时：%.2f U/h · 剩 %d 分钟",
                                                 cmd.rate, cmd.durationMinutes)
                    }
                }
            case .failure(let msg):
                self.tempBasalPendingVerify = false
                if quiet {
                    self.append("⚠️ 临时基础率回读失败（命令已下发，未能确认）：\(msg)")
                } else {
                    self.append("❌ 临时基础率查询失败：\(msg)")
                    self.statusLine = "临时基础率：失败 — \(msg)"
                }
            }
            completion?()
        }
        if reuse {
            runCommandOnLiveConnection(cmd, kind: "查询临时基础率", timeout: 30, completion: done)
        } else {
            runCommandPerConnection(cmd, kind: "查询临时基础率", completion: done)
        }
    }

    // MARK: - 临时基础率的本地状态 / 倒计时

    /// 记录一条临时基础率。minutes 是**剩余**分钟（下发时即设定时长）。
    private func applyTempBasal(rate: Double, minutes: Int, at: Date, pending: Bool) {
        tempBasalRate = rate
        tempBasalRemainingMin = max(0, minutes)
        tempBasalUntil = at.addingTimeInterval(TimeInterval(max(0, minutes) * 60))
        tempBasalSetAt = at
        tempBasalPendingVerify = pending
        startTempBasalTicker()
    }

    /// 清掉本地临时基础率状态（不含倒计时）。
    private func clearTempBasal() {
        tempBasalRate = nil
        tempBasalRemainingMin = nil
        tempBasalUntil = nil
        tempBasalSetAt = nil
        tempBasalPendingVerify = false
        stopTempBasalTicker()
    }

    /// 下发后的自动回读。碰上有别的命令在跑就放弃，不抢连接。
    private func verifyTempBasal(after seconds: Double) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard self.tempBasalPendingVerify else { return }
            guard !self.busy else {
                self.tempBasalPendingVerify = false
                self.append("（回读被其它命令占用，跳过。需要确认可手动点「查询」。）")
                return
            }
            self.queryTempBasal(quiet: true)
        }
    }

    /// 倒计时。每 20 秒按结束时刻重算剩余分钟，到点自动清空并提示。
    private func startTempBasalTicker() {
        stopTempBasalTicker()
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickTempBasal() }
        }
        RunLoop.main.add(t, forMode: .common)
        tempBasalTicker = t
    }

    private func stopTempBasalTicker() {
        tempBasalTicker?.invalidate()
        tempBasalTicker = nil
    }

    private func tickTempBasal() {
        guard let until = tempBasalUntil else { stopTempBasalTicker(); return }
        let remain = Int(ceil(until.timeIntervalSinceNow / 60.0))
        if remain <= 0 {
            clearTempBasal()
            append("⏱️ 临时基础率已到期（按设定时长结束，未回读确认）")
            statusLine = "临时基础率：已到期"
        } else if remain != tempBasalRemainingMin {
            tempBasalRemainingMin = remain
        }
    }

    /// 按命令连接执行器：暂停看门狗 → 新建连接 → onReady 时 run() → 恢复。
    /// 这解决了大剂量超时问题（扫描/看门狗竞争 + 半就绪连接）。
    private func runCommandPerConnection(_ cmd: EquilCommandDriving, kind: String,
                                         timeout: TimeInterval = 30,
                                         completion: ((EquilCommandRunner.Outcome) -> Void)? = nil) {
        ble.pauseWatchdog()
        var connArmed = true
        // 连接超时保护：若新连接 15 秒内未建立，
        // 不要让大剂量一直挂起（AAPS connectTimeOut=15000）。
        let connTimeout = DispatchWorkItem { [weak self] in
            guard let self, connArmed else { return }
            connArmed = false
            Task { @MainActor in
                self.ble.onReady = nil
                self.ble.onConnected = nil
                self.append("❌ \(kind) 失败：连接超时（15 秒）— 泵不可达")
                self.statusLine = "\(kind)：失败 — 连接超时"
                self.releaseBusy()
                // 有 completion 的调用方（批量刷新）必须收到一次结束通知，
                // 否则串行链会一直等在这里。
                completion?(.failure("连接超时（15 秒）"))
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: connTimeout)
        // 单次 onReady：只有在 CCCD notify 已启用
        // （即特征值可写）时才启动命令。早期版本用 onConnected，太早：
        // didConnect 之后 service/characteristic 发现尚未完成，
        // 于是 uartChar==nil → writeNext "no peripheral/char" → 断开 → 命令
        // 从未正常启动。AAPS 也在等价的 onReady 点写入（notify enabled）。
        ble.onReady = { [weak self] in
            guard let self else { return }
            self.ble.onReady = nil       // egyszeri
            Task { @MainActor in
                guard connArmed else { return }   // 连接超时已触发
                connArmed = false
                connTimeout.cancel()
                self.append("🔗 泵已就绪（notify 已启用）— 开始执行命令（\(kind)）")
                self.runner.run(command: cmd, timeout: timeout) { [weak self] outcome in
                    guard let self else { return }
                    if let completion {
                        Task { @MainActor in completion(outcome) }
                    } else {
                        self.handle(outcome, kind: kind)
                    }
                }
            }
        }
        if ble.isConnected {
            // 已有连接存在（看门狗维持）：connectForCommand 会断开并
            // 重新建立，让泵拿到干净的 GATT。此时 onConnected 也会触发。
            append("🔄 为执行命令刷新现有连接…")
            ble.connectForCommand()
        } else {
            append("🔌 连接已保存的泵（不扫描）…")
            ble.connectForCommand()
        }
    }

    /// 诊断扫描：列出附近全部 BLE 设备（不按 Equil 前缀
    /// 也不按 SN 过滤）。显示泵广播的准确名称与信号强度，
    /// 并标出输入的 SN 是否作为子串出现在名称中。
    /// 扫描附近设备。
    ///
    /// 默认**只报名称以 "Equil" 开头的设备**，附近的手环、耳机、电视都不会出现在列表里。
    /// 只有打开诊断开关（`showAllDevices`）才列出全部 BLE 设备。
    ///
    /// 注意：不拿 SN 做硬过滤。泵广播名的拼写随固件不同（`Equil-XXXXXX` 与
    /// `Equil - XXXXXX` 两种都见过），按 SN 硬过滤有可能把真泵挡在外面。
    /// SN 改为匹配后高亮 + 排到最前面。
    func startScan() {
        guard !busy else { return }
        discovered.removeAll()
        filteredOut = 0
        scanning = true
        statusLine = "扫描中…"
        append(showAllDevices
               ? "=== 扫描开始（诊断模式：显示全部 BLE 设备）==="
               : "=== 扫描开始（只显示 Equil 泵）===")

        if showAllDevices {
            ble.nameFilterPrefix = nil
            ble.nameFilterContains = nil
        } else {
            ble.nameFilterPrefix = "Equil"
            ble.nameFilterContains = nil
        }

        let knownSN = serialNumber.uppercased()
        ble.onDiscover = { [weak self] peripheral, name, rssi in
            Task { @MainActor in
                guard let self else { return }
                let id = peripheral.identifier.uuidString
                // peripheral 只在这里被强引用，扫描页关掉后 CBPeripheral 会被回收，
                // 所以按 UUID 留一份，配对时直接用，省掉一次重新扫描。
                self.peripheralCache[id] = peripheral
                let parsed = EquilUtils.parseSerial(from: name)
                let match = !knownSN.isEmpty && parsed == knownSN
                if let i = self.discovered.firstIndex(where: { $0.id == id }) {
                    // 同一台设备再次广播：刷新信号强度，不重复添加
                    self.discovered[i].rssi = rssi
                    self.discovered[i].serial = parsed
                    self.discovered[i].matchesSerial = match
                } else {
                    self.discovered.append(DiscoveredDevice(id: id, name: name, rssi: rssi,
                                                            serial: parsed, matchesSerial: match))
                    let snText = parsed.map { "  SN=\($0)" } ?? "  （名字里没有 SN）"
                    self.append("📡 \(name)  \(rssi) dBm\(snText)\(match ? "  ◀ 上次配对的那台" : "")")
                }
                // 已知的那台排最前，其余按信号强度
                self.discovered.sort {
                    if $0.matchesSerial != $1.matchesSerial { return $0.matchesSerial }
                    return $0.rssi > $1.rssi
                }
                self.filteredOut = self.ble.filteredCount

                // 启动时的自动扫描：只认 SN 对得上的那台，扫到即连（不连陌生泵）。
                if self.autoPickAfterScan, match {
                    self.autoPickAfterScan = false
                    self.append("✅ 扫到上次配对的那台（SN \(knownSN)）— 直接连接")
                    self.ble.holdPeripheral(peripheral)   // 句柄交给 BLE 层，并落盘标识
                    self.stopScan()
                    self.refreshStatus()
                }
            }
        }
        ble.startScan()
    }

    func stopScan() {
        ble.stopScan()
        scanning = false
        filteredOut = ble.filteredCount
        statusLine = "扫描已停止（\(discovered.count) 台）"
        append("=== 扫描停止：发现 \(discovered.count) 台，过滤掉 \(filteredOut) 台非 Equil 设备 ===")
        if showAllDevices {
            append("（诊断模式：本次未做名称过滤，上面数字仅供参考）")
            return
        }
        if discovered.isEmpty {
            append("⚠️ 没有发现 Equil 泵。检查：泵已装电池并开机、没被泵控制器 占着连接、距离 1 米内。")
        } else if discovered.contains(where: { $0.serial != nil }) {
            append("✅ 发现 \(discovered.count) 台 Equil 设备，点一下你要配对的那台。")
        } else {
            append("⚠️ 发现 \(discovered.count) 台 Equil 设备，但名字里都读不出 SN。仍可点选配对，请确认就是要配的那台泵。")
        }
    }

    func clearLog() { logLines.removeAll() }

    // MARK: BT 看门狗控制
    @Published var watchdogOn: Bool = false

    /// 配对成功后：只保留 peripheral（ID + 引用），以便
    /// 下一条命令免扫描直接连接（connectForCommand）。没有看门狗，
    /// 也没有常驻连接 — 遵循 AAPS 按命令连接模型：泵约 11 秒
    /// 空闲后自行断开，每条命令都重新连接。
    func activateWatchdogAfterPairing() {
        guard let p = ble.currentPeripheral else {
            append("⚠️ 配对后没有可用的 peripheral — 已跳过")
            return
        }
        ble.holdPeripheral(p)   // 仅保存引用（watchdogEnabled 保持，但不自动重连/定时器）
        watchdogOn = false
        append("✅ 泵已保存（供免扫描重连）。按命令连接模式 — 无看门狗。")
    }

    /// 手动看门狗开关（UI）。
    func toggleWatchdog() {
        if watchdogOn {
            ble.stopWatchdog()
            watchdogOn = false
            append("🐕 Watchdog KIKAPCSOLVA.")
        } else if let p = ble.currentPeripheral {
            ble.holdPeripheral(p)
            ble.startWatchdog(intervalSeconds: 3)
            watchdogOn = true
            append("🐕 Watchdog BEKAPCSOLVA.")
        } else {
            append("⚠️ 看门狗：请先配对（无 peripheral）。")
        }
    }

    // MARK: Helpers
    private func handle(_ outcome: EquilCommandRunner.Outcome, kind: String) {
        releaseBusy()
        switch outcome {
        case .success(let enacted):
            // 界面只写「成功」；enacted 是协议层的位，留给日志。
            statusLine = "\(kind)：成功"
            append("✅ \(kind) 成功（enacted=\(enacted)）")
        case .failure(let msg):
            statusLine = "\(kind)：失败 — \(msg)"
            append("❌ \(kind) 失败：\(msg)")
        }
        // 按命令连接收尾：命令已完成（成功/失败）。无看门狗/重连：
        // 让泵自行断开（约 11 秒），下一条命令重新连接。
        // onReady 归 runner 所有（handleReady 自带空命令保护），这里只清 onConnected，
        // 免得下一次命令/配对因为槽位被清空而永远等不到首包。
    }

    private func append(_ line: String) {
        let ts = Self.tsFormatter.string(from: Date())
        let entry = "\(ts)  \(line)"
        logLines.append(entry)
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
        oslog.log("\(line, privacy: .public)")
        logServer.append(line)   // 同步到 HTTP 日志服务器（可用 curl 读取）
    }

    private static let tsFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    private static func describe(_ s: CBManagerState) -> String {
        switch s {
        case .poweredOn: return "已开启"
        case .poweredOff: return "已关闭"
        case .unauthorized: return "未授权"
        case .unsupported: return "不支持"
        case .resetting: return "重启中"
        default: return "未知"
        }
    }
}
