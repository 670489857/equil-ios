import CoreBluetooth
import Foundation

/// Drives a single Equil command sequence (pairing or bolus) over the BLE transport.
///
/// Byte-parity reference: AndroidAPS `pump/equil/ble/EquilBLE.kt` orchestration
/// (writeCmd → ready → writeData → onCharacteristicWrite loop, onCharacteristicChanged
/// → decode → writeConf) combined with `EquilManager` command lifecycle.
///
/// Flow:
///   1. Caller builds a command (CmdPair / CmdLargeBasalSet), calls run(command:).
///   2. We reset shared state, connect/scan via EquilBLEManager.
///   3. onReady (CCCD enabled) → command.getEquilResponse() → push packets.
///   4. onNotify(frame) → command.decodeEquilPacket(frame):
///        - returns nil  → waiting for more packets, do nothing.
///        - returns next → push next.send packets.
///   5. When command.cmdSuccess becomes true (or isEnd) → finish(success).
///   6. Timeout guard mirrors EquilConst.EQUIL_CMD_TIME_OUT semantics.
final class EquilCommandRunner {

    enum Outcome {
        case success(enacted: Bool)
        case failure(String)
    }

    private let ble: EquilBLEManager
    private var command: EquilCommandDriving?
    private var completion: ((Outcome) -> Void)?
    private var finished = false
    private var timeoutWork: DispatchWorkItem?

    /// 上一条**成功**命令留下的会话凭据（runPwd / runCode）。
    /// AAPS 用 `preCmd` 保存上一条 BaseCmd，同一条连接上的下一条命令
    /// 直接拿它的 runPwd / runCode 走 `nextCmd2()`，跳过 1、2 号报文 ——
    /// 泵只在新会话里接受完整握手，旧会话上再来一遍会直接不回包。
    private(set) var lastSessionPwd: String?
    private(set) var lastSessionCode: String?
    /// 是否有一条可复用的会话（连接还活着时才有意义）。
    var hasReusableSession: Bool { lastSessionPwd != nil }
    /// 本次 run 是否要求复用会话。
    private var reuseSession = false
    /// 首包是否已发出。onReady 可能被多次触发，重复发首包会让泵把后一包当重放丢弃。
    private var firstPacketSent = false

    /// Forwarded log line (BLE + protocol). Wire to UI/os_log.
    var onLog: ((String) -> Void)?

    /// Párosításkor: a felfedezett (valódi) eszköznévből újraépíti a CmdPair-t,
    /// mert a sorozatszám (sn) a névből származik. Ha nil, a megadott parancs marad.
    var pendingPairFactory: ((_ discoveredName: String) -> EquilCommandDriving)?
    /// A legutóbb futtatott CmdPair (a kialkudott device/password kiolvasásához).
    private(set) var lastPairCommand: CmdPair?

    // MARK: - Többlépéses párosítási flow állapot (AAPS EquilPairSerialNumberFragment)
    /// A felfedezett pump neve+címe (a SN-szűrt scan eredménye).
    private var pairDiscoveredName: String?
    private var pairDiscoveredAddress: String?
    /// A párosítási lépéseket előállító closure-ök (sorrendben).
    /// Mindegyik a felfedezett (name,address) ismeretében épít parancsot, és a
    /// `step(after:)` callback dönti el, lép-e tovább (a parancs eredménye alapján).
    private var pairPipeline: [(_ name: String, _ address: String) -> EquilCommandDriving]?
    private var pairStepIndex = 0
    /// A párosítási flow paraméterei.
    private var pairSerialNumber: String?
    private var pairPassword: String?
    private var pairMaxBolus: Double = 0
    private var pairMaxBasal: Double = 0
    /// A frissen párosított device/password (CmdPair-ből).
    private(set) var pairedDevice: String?
    private(set) var pairedPassword: String?

    /// 配对第 1 步（CmdDevicesOldGet）读回来的固件版本，例如 "5.3"。
    /// 这是唯一在配对阶段就能拿到固件号的时机，丢掉它就得再连一次泵。
    private(set) var lastFirmwareText: String?
    private(set) var lastFirmwareValue: Float = 0

    /// 清除本地保存的配对信息。仅影响本机，不向泵发送 CmdUnPair。
    /// （AAPS 的 Unpair 会发 CmdUnPair 让泵解除绑定，这个版本尚未移植该命令。）
    func clearPairing() {
        pairedDevice = nil
        pairedPassword = nil
    }
    /// A teljes párosítási flow lezárása.
    private var pairCompletion: ((Outcome) -> Void)?
    /// Igaz, amíg a többlépéses párosítás fut (a single-command finish ezt nem zárja le).
    private var pairingActive = false

    init(ble: EquilBLEManager) {
        self.ble = ble
        wireBLE()
    }

    private func wireBLE() {
        ble.onLog = { [weak self] in self?.log("[BLE] \($0)") }
        ble.onReady = { [weak self] in self?.handleReady() }
        ble.onNotify = { [weak self] in self?.handleNotify($0) }
        ble.onDisconnected = { [weak self] err in
            guard let self else { return }
            self.log("[BLE] disconnected: \(err?.localizedDescription ?? "clean")")
            // 链路没了，会话也就没了。
            self.lastSessionPwd = nil
            self.lastSessionCode = nil
        }
        installDiscoverHandler()
    }

    /// 把「发现设备 → 记录名字/地址 → 建立连接」挂到 BLE 层。
    ///
    /// 单独抽出来是因为 `onDiscover` 只有一个槽位：扫描页也会占用它。
    /// 若用户先开过扫描页再配对，runner 的 handler 已被覆盖，配对就会一直
    /// 等不到设备直到超时。所以每次 `runPairing` 前都要重新装一次。
    func installDiscoverHandler() {
        ble.onDiscover = { [weak self] peripheral, name, _ in
            guard let self else { return }
            self.log("[BLE] discovered \(name) — connecting")
            // 多步配对：记下发现的名字与地址（iOS 上地址就是 peripheral UUID，
            // 只作连接标识，不进加密载荷）。
            if self.pairingActive {
                self.pairDiscoveredName = name
                self.pairDiscoveredAddress = peripheral.identifier.uuidString
            }
            // 单命令配对（旧路径）：用真实名字重建 CmdPair。
            if let factory = self.pendingPairFactory {
                let rebuilt = factory(name)
                self.command = rebuilt
                if let pair = rebuilt as? CmdPair { self.lastPairCommand = pair }
                self.pendingPairFactory = nil
            }
            self.ble.connect(peripheral)
        }
    }

    /// Run one command sequence. `timeout` defaults to EQUIL_CMD_TIME_OUT-ish (sane 30s).
    ///
    /// - Parameter resetState: 是否把 reqIndex/pumpReqIndex/rspIndex 归零。
    ///   单条命令（新连接、新会话）必须归零；排气这种「同一条连接连着发多条」
    ///   的循环不能归零 —— AAPS 的 fill 循环里这几个计数器全程单调递增，
    ///   归零会让泵把后续报文当成重放而丢弃。
    func run(command: EquilCommandDriving,
             timeout: TimeInterval = 30,
             resetState: Bool = true,
             reuseSession: Bool = false,
             completion: @escaping (Outcome) -> Void) {
        if resetState {
            EquilBaseCmd.resetState()       // reqIndex/pumpReqIndex/rspIndex → kezdőérték
            // 全新会话：旧的凭据属于上一轮 GATT，必须丢掉，否则会被误用。
            lastSessionPwd = nil
            lastSessionCode = nil
        }
        // 上一条命令（可能是被用户中途放弃的那次）的超时计时器必须先取消：
        // 它属于旧命令，留在队列里到点就会把**这次**新命令判成超时。
        timeoutWork?.cancel()
        timeoutWork = nil
        self.command = command
        self.completion = completion
        self.finished = false
        self.reuseSession = reuseSession
        self.firstPacketSent = false
        if let pair = command as? CmdPair { self.lastPairCommand = pair }
        log("RUN \(command.label) — scanning")

        let work = DispatchWorkItem { [weak self] in
            self?.finish(.failure("időtúllépés (\(Int(timeout))s)"))
        }
        timeoutWork = work
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: work)

        // onReady 的所有权在这里收回：上一轮 `runCommandPerConnection` 会在收尾时
        // 把它置 nil，连接一旦中途断掉就没人再发首包 —— 表现正是「第二条命令等 30 秒
        // 然后报 időtúllépés」。每次 run 都重新挂一次，多挂不影响：handleReady 自带
        // `guard let command`，空闲时是空操作。
        ble.onReady = { [weak self] in self?.handleReady() }

        if ble.isConnected && ble.isReady {
            handleReady()                   // 链路与 CCCD 都就绪：直接发第 1 条消息
        } else if ble.isConnected {
            // 已连上但 notify 还没开：等 onReady（上面刚挂好），不要抢在特征值发现前写包
            log("已连接但传输未就绪 — 等待 CCCD")
        } else if ble.hasKnownPeripheral {
            // 已经认得这台泵就直接重连，不要盲扫：泵被系统占着或暂不广播时，
            // 扫描永远等不到设备，只能干等到命令超时。AAPS 的 closeBleAuto 之后
            // 也是拿地址直连，不重新扫。
            log("未连接但已知设备 — 直连重试（不扫描）")
            ble.connectForCommand()
        } else {
            // 扫描页可能把 onDiscover 换掉了、也可能留下了「显示全部设备」的过滤器。
            // 发命令前恢复成「只认 Equil + runner 自己处理发现事件」。
            installDiscoverHandler()
            ble.nameFilterPrefix = "Equil"
            ble.nameFilterContains = nil
            ble.startScan()
        }
    }

    // MARK: - BLE event handlers
    private func handleReady() {
        // 兜底：被直接调用时若 notify 尚未启用，发出去的包会因 uartChar==nil
        // 被传输层断开，命令等于没发。等真正的 onReady 再来。
        guard ble.isReady else {
            log("onReady 到达但传输未就绪 — 继续等待")
            return
        }
        // A CCCD engedélyezése (onReady) EGYSZER történik a kapcsolat után.
        // Többlépéses párosításnál ekkor indítjuk az ELSŐ lépést (CmdDevicesOldGet).
        if pairingActive && command == nil {
            startPairStep()
            return
        }
        guard let command, !firstPacketSent else { return }
        do {
            let resp: EquilResponse
            if reuseSession, let pwd = lastSessionPwd {
                // AAPS EquilBLE.nextCmd2(): 复用上一条命令的 runPwd / runCode，
                // 直接发 getFirstData()，不重做「请求 → 回密钥 → 再发」。
                log("↻ 复用上一条命令的会话（跳过 1/2 号报文）")
                resp = try command.reuseSessionResponse(pwd: pwd, code: lastSessionCode)
            } else {
                if reuseSession { log("⚠️ 没有可复用的会话凭据 — 退回完整握手") }
                resp = try command.firstResponse()
            }
            firstPacketSent = true
            log("→ küldés: \(resp.send.count) csomag (1. üzenet)")
            ble.send(packets: resp.send.map { Data($0) })
        } catch {
            finishCommand(.failure("firstResponse hiba: \(error)"))
        }
    }

    private func handleNotify(_ frame: Data) {
        guard let command, !finished else { return }
        let bytes = [UInt8](frame)
        let next = command.decodeEquilPacket(bytes)   // állapotgép

        if command.cmdSuccess {
            log("✓ cmdSuccess (enacted=\(command.enacted))")
            finishCommand(.success(enacted: command.enacted))
            return
        }
        if let next, !next.send.isEmpty {
            log("→ küldés: \(next.send.count) csomag (következő üzenet)")
            ble.send(packets: next.send.map { Data($0) })
        }
        // ha next == nil és nincs cmdSuccess: még gyűlnek a csomagok, várunk
    }

    /// Egy parancs (lépés) befejeződött. Többlépéses párosításnál a pipeline-t lépteti,
    /// egyparancsos futtatásnál a teljes flow-t zárja (finish).
    private func finishCommand(_ outcome: Outcome) {
        if pairingActive {
            advancePairing(after: outcome)
        } else {
            finish(outcome)
        }
    }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        timeoutWork?.cancel()
        timeoutWork = nil
        // 会话凭据只在成功时保留：失败/超时说明泵那边状态未知，
        // 下一条命令必须重连、重新协商，不能拿旧密钥硬发。
        if case .success = outcome, let cmd = command, let pwd = cmd.sessionPwd {
            lastSessionPwd = pwd
            lastSessionCode = cmd.sessionCode
        } else {
            lastSessionPwd = nil
            lastSessionCode = nil
        }
        switch outcome {
        case .success(let enacted): log("BEFEJEZVE: siker (enacted=\(enacted))")
        case .failure(let msg):     log("BEFEJEZVE: hiba — \(msg)")
        }
        // Többlépéses párosítás lezárása (pl. időtúllépés a teljes flow-ra).
        let pairCb = pairCompletion
        let singleCb = completion
        resetPairingState()
        completion = nil
        command = nil
        if let pairCb { DispatchQueue.main.async { pairCb(outcome) } }
        else if let singleCb { DispatchQueue.main.async { singleCb(outcome) } }
    }

    private func resetPairingState() {
        pairingActive = false
        pairPipeline = nil
        pairStepIndex = 0
        pairCompletion = nil
        pairDiscoveredName = nil
        pairDiscoveredAddress = nil
        pairSerialNumber = nil
        pairPassword = nil
    }

    private func log(_ msg: String) { onLog?(msg) }

    // MARK: - Többlépéses párosítási flow (AAPS EquilPairSerialNumberFragment-hű)
    //
    //  Sorrend (mind a SAME BLE-kapcsolaton, EGY resetState()-tel az elején):
    //    0) SN-szűrt scan (name.contains(serialNumber)) → connect → CCCD ready
    //    1) CmdDevicesOldGet(address) → siker && isSupport(SN) → vár 500 ms
    //    2) CmdPair(name, address, password) → siker && enacted → vár 500 ms
    //    3) CmdSettingSet(maxBolus, maxBasal) → siker → device/SN mentés
    //
    //  A pumpReqIndex/reqIndex/rspIndex statikus és a teljes flow alatt FOLYAMATOSAN
    //  nő — ezért resetState() csak EGYSZER, a flow elején.
    //
    //  `targetPeripheral` 是「用户已经在扫描页里点选了这台泵」的路径：直接连它，
    //  不再按名字重新扫一遍。SN 此时由 `advertisedName` 解析得到，用户从没手输过。
    func runPairing(serialNumber: String,
                    advertisedName: String? = nil,
                    password: String,
                    maxBolus: Double,
                    maxBasal: Double,
                    targetPeripheral: CBPeripheral? = nil,
                    timeout: TimeInterval = 90,
                    completion: @escaping (Outcome) -> Void) {
        EquilBaseCmd.resetState()
        // 同样要清掉上一次配对（含被用户中途退出那次）留下的超时计时器，
        // 否则它到点会把这次配对判成失败 —— 表现就是「配对卡住，杀后台重进才好」。
        timeoutWork?.cancel()
        timeoutWork = nil
        // onReady 在配对收尾时被置过 nil：只靠 init 里那一次接线的话，第二次配对
        // 连上泵后没人发首包，界面永远停在「正在配对…」。每次配对都重挂。
        ble.onReady = { [weak self] in self?.handleReady() }
        finished = false
        pairingActive = true
        pairCompletion = completion
        pairSerialNumber = serialNumber
        pairPassword = password
        pairMaxBolus = maxBolus
        pairMaxBasal = maxBasal
        pairStepIndex = 0
        pairedDevice = nil
        pairedPassword = nil
        command = nil

        // 直接连接路径拿不到 onDiscover，名字与地址要提前塞进状态，
        // 否则 startPairStep 会拿 "Equil" 当名字，sn 解析出来是空的。
        if let target = targetPeripheral {
            pairDiscoveredName = advertisedName ?? target.name
            pairDiscoveredAddress = target.identifier.uuidString
        }

        let now: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
        pairPipeline = [
            // 1) CmdDevicesOldGet — firmware lekérdezés
            { _, address in
                CmdDevicesOldGet(address: address, createTime: now())
            },
            // 2) CmdPair — a sn a felfedezett NÉVBŐL származik
            { [weak self] name, address in
                let pwd = self?.pairPassword ?? password
                let cmd = CmdPair(name: name, address: address, pairPassword: pwd, createTime: now())
                self?.lastPairCommand = cmd
                return cmd
            },
            // 3) CmdSettingSet — a CmdPair-ből kialkudott device/password-del
            { [weak self] _, _ in
                let dev = self?.pairedDevice ?? ""
                let pw = self?.pairedPassword ?? ""
                return CmdSettingSet(maxBolus: maxBolus, maxBasal: maxBasal,
                                     equilDevice: dev, equilPassword: pw, createTime: now())
            }
        ]

        log("=== PÁROSÍTÁS (4 lépés) START — SN=\(serialNumber.isEmpty ? "(由广播名解析)" : serialNumber) ===")

        let work = DispatchWorkItem { [weak self] in
            self?.finish(.failure("párosítás időtúllépés (\(Int(timeout))s)"))
        }
        timeoutWork = work
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: work)

        if let target = targetPeripheral {
            // 用户点选的那台泵：直接连，不扫描。名字前缀过滤无关紧要，
            // 因为不会再产生任何 onDiscover 事件。
            log("直接连接已选设备 \(pairDiscoveredName ?? "?") — 跳过扫描")
            ble.nameFilterContains = nil
            ble.nameFilterPrefix = "Equil"
            installDiscoverHandler()
            if ble.isConnected, ble.currentPeripheral?.identifier == target.identifier,
               ble.isReady {
                log("已与该设备保持连接且传输就绪，直接进入配对流程")
                handleReady()
            } else if ble.isConnected, ble.currentPeripheral?.identifier == target.identifier {
                // 连着但 notify 还没开：等 onReady 自己进来，别抢跑
                log("已与该设备连接，等待 CCCD 就绪后开始配对")
            } else {
                ble.connect(target)
            }
            return
        }

        ble.nameFilterContains = serialNumber.isEmpty ? nil : serialNumber
        ble.nameFilterPrefix = "Equil"      // 配对只认泵，别连到别的设备
        installDiscoverHandler()            // 扫描页可能占用了槽位，这里重新装
        if ble.isConnected && ble.isReady {
            handleReady()
        } else if ble.isConnected {
            log("已连接但传输未就绪 — 等 onReady")
        } else {
            ble.startScan()
            // 降级：泵广播名的拼写随固件不同（`Equil-XXXXXX` / `Equil - XXXXXX` / 不带 SN）。
            // 8 秒还没发现「名字含 SN」的设备，就放宽成只按 Equil 前缀扫一次，
            // 否则会在一种命名上永远配不上。SN 的核对仍然由 CmdPair 的 name 参数完成。
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, self.pairingActive, self.pairDiscoveredName == nil else { return }
                self.log("8 秒内没有名称含 SN 的泵 —— 放宽为只按 Equil 前缀扫描")
                self.ble.nameFilterContains = nil
                self.ble.stopScan()
                self.ble.startScan()
            }
        }
    }

    /// Elindítja az aktuális párosítási lépést (parancs építés + 1. üzenet küldés).
    private func startPairStep() {
        guard let pipeline = pairPipeline, pairStepIndex < pipeline.count else {
            finishPairingSuccess()
            return
        }
        let name = pairDiscoveredName ?? "Equil"
        let address = pairDiscoveredAddress ?? ""
        let cmd = pipeline[pairStepIndex](name, address)
        command = cmd
        log("—— Párosítási lépés \(pairStepIndex + 1)/\(pipeline.count): \(cmd.label) ——")
        do {
            let resp = try cmd.firstResponse()
            log("→ küldés: \(resp.send.count) csomag (lépés 1. üzenet)")
            ble.send(packets: resp.send.map { Data($0) })
        } catch {
            finish(.failure("lépés \(pairStepIndex + 1) firstResponse hiba: \(error)"))
        }
    }

    /// Egy párosítási lépés befejeződött — döntés a továbblépésről (AAPS gating).
    private func advancePairing(after outcome: Outcome) {
        guard pairingActive else { return }
        let finishedCmd = command
        command = nil

        guard case .success(let enacted) = outcome else {
            if case .failure(let msg) = outcome { finish(.failure("párosítás lépés hiba: \(msg)")) }
            return
        }

        switch finishedCmd {
        case let dev as CmdDevicesOldGet:
            let sn = pairSerialNumber ?? ""
            lastFirmwareValue = dev.firmwareVersion
            // 0 表示解析失败（回包长度不对），不要当成 "0.0 版本"。
            lastFirmwareText = dev.firmwareVersion > 0
                ? String(format: "%.1f", dev.firmwareVersion)
                : nil
            if !dev.isSupport(serialNumber: sn) {
                finish(.failure("nem támogatott firmware (fw=\(dev.firmwareVersion) < \(EquilConst.EQUIL_SUPPORT_LEVEL))"))
                return
            }
            log("firmware=\(dev.firmwareVersion) — támogatott")
        case let pair as CmdPair:
            if !enacted {
                finish(.failure("párosítás elutasítva (rossz jelszó vagy már párosítva)"))
                return
            }
            pairedDevice = pair.newDevice
            pairedPassword = pair.newPassword
            log("CmdPair OK — device=\(pair.newDevice ?? "?") password=\(pair.newPassword ?? "?")")
        default:
            break  // CmdSettingSet: csak siker kell
        }

        pairStepIndex += 1
        guard let pipeline = pairPipeline, pairStepIndex < pipeline.count else {
            finishPairingSuccess()
            return
        }

        let delayMs = Int(EquilConst.EQUIL_BLE_NEXT_CMD)
        log("várakozás \(delayMs) ms a következő lépés előtt")
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
            self?.startPairStep()
        }
    }

    private func finishPairingSuccess() {
        log("=== PÁROSÍTÁS KÉSZ — device/SN menthető ===")
        finish(.success(enacted: true))
    }
}

/// A futtatható parancs minimális felülete, amit a runner használ.
/// A CmdPair és CmdLargeBasalSet ezt adja (EquilBaseCmd-n keresztül).
protocol EquilCommandDriving: AnyObject {
    var label: String { get }
    var cmdSuccess: Bool { get }
    var enacted: Bool { get }
    func firstResponse() throws -> EquilResponse
    func decodeEquilPacket(_ data: [UInt8]) -> EquilResponse?
    /// 本条命令结束时的会话凭据（runPwd / runCode）。
    var sessionPwd: String? { get }
    var sessionCode: String? { get }
    /// 复用已建立的会话：直接用 pwd/code 加密 getFirstData() 发出。
    func reuseSessionResponse(pwd: String, code: String?) throws -> EquilResponse
}
