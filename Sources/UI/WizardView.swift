//
//  WizardView.swift
//  EquilController
//
//  对应 AAPS 4.0 的 EquilWizardScreen + EquilWizardStep。
//
//  AAPS 的向导按 EquilWorkflow 生成步骤序列：
//    PAIR           : 装配 → 扫描 → 密码 → [选胰岛素] → 填充 → [部位] → 贴附 → 排气 → 确认
//    CHANGE_INSULIN : 换药 → 装配 → [选胰岛素] → 填充 → [部位] → 贴附 → [排气] → 确认
//    UNPAIR         : 拆卸 → 确认
//
//  这里实现核心子集，顺序与 AAPS 前半段一致：
//    装配 → 扫描并选中泵 → 输密码（配对）→ 排气（完成后自动切运行中）→ 确认
//
//  两个硬约束（都照 AAPS 来）：
//    1. 不手填 SN。SN 是泵广播名的一部分（`Equil - A1B2C3`），扫描到就直接有了。
//       标签上什么都不用抄：密码是可选的，由用户自定，泵身标签上没有密码。
//    2. 扫描步必须真的看到并选中一台泵才能进下一步；密码步必须配对成功才能进排气。
//       没有「跳过」按钮，也不接受上次残留的选择——那台泵可能已经不在旁边了。
//

import SwiftUI

struct WizardView: View {
    @ObservedObject var model: EquilControllerModel
    let flow: EquilControllerModel.Route

    @State private var index = 0
    @State private var showExitConfirm = false

    private var steps: [WizardStepKind] {
        switch flow {
        case .wizardPair:
            // 不再单列「设为 RUN」一页：排气完成点「下一步」时自动发 CmdModelSet(RUN=1)，
            // 与 AAPS 配对末尾自动切运行一致。
            return [.assemble, .scanPick, .password, .fill, .confirm]
        case .wizardChange:
            // AAPS 的 CHANGE_INSULIN 第一步是 CmdInsulinChange：推杆退到限位，
            // 卸下旧储药器、装新的，再进入填充/排气。缺这一步时旧推杆顶在活塞上，
            // 排气一推就撞限位，阻力检测直接失败。
            return [.changeInsulin, .assemble, .fill, .confirm]
        case .wizardUnpair:
            return [.unpairWarn, .unpairConfirm]
        default:
            return []
        }
    }

    private var current: WizardStepKind? {
        guard index >= 0 && index < steps.count else { return nil }
        return steps[index]
    }

    /// 选中的泵必须来自**本次**扫描结果。从磁盘恢复的旧选择不算。
    private var pickedInThisScan: Bool {
        guard let s = model.selectedDevice else { return false }
        return model.discovered.contains { $0.id == s.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            StepProgressIndicator(current: index + 1, total: steps.count)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let step = current {
                        Text(step.title)
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        stepBody(step)
                    }
                }
                .padding(20)
            }

            bottomBar
        }
        .navigationTitle(titleText)
        .navigationBarTitleDisplayMode(.inline)
        // 系统返回键（「< Equil 泵」）与下面自定义的 chevron 会叠成两个箭头，
        // 只保留自己那个：它走「退出向导？」确认，不会静默丢掉未完成状态。
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showExitConfirm = true
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!canGoBack)
            }
        }
        .alert("退出向导？", isPresented: $showExitConfirm) {
            Button("继续操作", role: .cancel) {}
            Button("退出", role: .destructive) {
                model.stopScan()
                model.route = .overview
            }
        } message: {
            Text("中途退出可能导致泵停留在未完成状态。若已配对但尚未切到运行中，建议先走完。")
        }
        // 进入扫描步就重扫：清掉上次残留的选择，从零开始找泵。
        .onChange(of: index) { _, new in
            guard steps.indices.contains(new) else { return }
            if steps[new] == .scanPick, !model.busy {
                model.restartPairScan()
            }
            // 不再预查运行模式：排气完成时会无条件重发一次 CmdModelSet(mode=1)
            // （AAPS 配对末尾同样是无条件切运行），缓存不可信也没关系。
        }
        // 配对是异步的（4 条命令、通常十几秒）。成功才允许进入排气。
        .onChange(of: model.pairingState) { _, new in
            if new == .paired, current == .password {
                index += 1
            }
        }
        .onAppear {
            // 配对 / 换敷贴都要重新排气（换了储药器或敷贴），别沿用上一次的完成标记。
            if flow == .wizardPair || flow == .wizardChange {
                model.resetPrimeState()
            }
        }
        .onDisappear {
            // 向导结束（完成或退出）时别让扫描在后台空转
            if model.scanning { model.stopScan() }
        }
    }

    private var titleText: String {
        switch flow {
        case .wizardPair:   return "配对"
        case .wizardChange: return "换敷贴"
        case .wizardUnpair: return "解绑"
        default:            return ""
        }
    }

    private var canGoBack: Bool { true }

    // 只留 0-9A-F、转大写、截断到 4 位。
    private var passwordBinding: Binding<String> {
        Binding(
            get: { model.pairPassword },
            set: { newValue in
                let clean = EquilControllerModel.normalizeHex(newValue, length: 4)
                guard clean != model.pairPassword else { return }
                model.pairPassword = clean
                model.persistIdentity()
            }
        )
    }

    // MARK: - 步骤内容

    @ViewBuilder
    private func stepBody(_ step: WizardStepKind) -> some View {
        switch step {
        case .changeInsulin:
            VStack(alignment: .leading, spacing: 12) {
                Text("先把推杆退回去，才能取下旧储药器。")
                    .font(.subheadline)
                Bullet("点下面的「推杆退回」，等它走到限位（约十几秒）。")
                Bullet("退回后取下旧储药器，装入新储药器与电池。")
                Bullet("推杆退到底后，泵会进入「已停止」，这是正常的 —— 排气完成后会自动切回运行中。")
                if model.busy {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(model.statusLine).font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Text(model.statusLine)
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Callout(text: "退回会真的驱动推杆，先把泵从身上取下。", level: .critical)
            }

        case .assemble:
            VStack(alignment: .leading, spacing: 12) {
                Bullet("准备好储药器与电池，泵体暂不贴到身上。")
                Bullet("确认手机蓝牙已开启，泵在 1 米范围内。")
            }

        case .scanPick:
            scanPickBody

        case .password:
            passwordBody

        case .fill:
            VStack(alignment: .leading, spacing: 12) {
                if model.isPaired {
                    InfoRow(label: "已配对", value: model.selectedDevice?.name ?? model.serialNumber,
                            level: .normal)
                } else {
                    Callout(text: "还没有配对成功，排气会被泵拒绝。回到上一步重新输密码。", level: .critical)
                }
                Text("推杆会连续推进多次，直到阻力达到阈值。")
                    .font(.subheadline)
                if model.busy {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(model.statusLine).font(.footnote).foregroundStyle(.secondary)
                    }
                } else if model.primeCompleted {
                    InfoRow(label: "排气", value: "已完成", level: .normal)
                    Text(model.runMode == .run
                         ? "推杆已到位，泵已进入运行中。点「下一步」继续。"
                         : "推杆已到位。点「下一步」会自动把泵切到运行中。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if model.runMode != .run, !model.statusLine.isEmpty {
                        Text(model.statusLine)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Text(model.statusLine)
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Callout(text: "泵此时必须离体，且针头朝上、不接触任何物体。排气会把胰岛素推出来。", level: .critical)
            }

        case .runMode:
            // 已并入排气步：排气完成点「下一步」时自动发 CmdModelSet(mode=1)。
            // 保留这个 case 只是为了让 switch 穷尽（step 序列里已不再出现）。
            EmptyView()

        case .confirm:
            VStack(alignment: .leading, spacing: 12) {
                InfoRow(label: "设备", value: model.selectedDevice?.name ?? "—")
                InfoRow(label: "序列号", value: model.serialNumber.isEmpty ? "—" : model.serialNumber)
                InfoRow(label: "运行模式", value: model.runMode.displayName)
                InfoRow(label: "胰岛素余量", value: model.reservoirUnits.map { "\($0) U" } ?? "未读取")
                InfoRow(label: "初始化", value: model.activationCompleted ? "已完成" : "未完成")
            }

        case .unpairWarn:
            VStack(alignment: .leading, spacing: 12) {
                Callout(text: "解绑会停止输注，并把推杆退回到底、清除本机配对。退回前请确认泵已从身上取下。", level: .critical)
            }

        case .unpairConfirm:
            VStack(alignment: .leading, spacing: 12) {
                Text("确认解绑？这一步会真的驱动推杆。")
                    .font(.subheadline)
                InfoRow(label: "设备",
                        value: model.selectedDevice?.name
                            ?? (model.pairedDevice.isEmpty ? "—" : String(model.pairedDevice.prefix(16)) + "…"))
                InfoRow(label: "将执行", value: "推杆退回 → 清除配对")
                if model.busy {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(model.statusLine).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Callout(text: "泵不在附近时两条命令都会等 30 秒超时，之后仍会清除本机配对（推杆不会退回）。",
                        level: .warning)
            }
        }
    }

    // MARK: - 扫描步

    private var scanPickBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if model.scanning {
                    ProgressView().controlSize(.small)
                    Text("正在收听广播…").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                    Text("扫描已停止").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.scanning ? "停止" : "重新扫描") {
                    model.scanning ? model.stopScan() : model.restartPairScan()
                }
                .font(.footnote)
                .disabled(model.busy)
            }

            if model.discovered.isEmpty {
                Callout(text: model.scanning
                        ? "还没有收到任何 Equil 泵的广播。把泵靠近手机、确认已装电池并开机、泵控制器 没有连着它。"
                        : "没有发现泵。点「重新扫描」再试一次。",
                        level: .warning)
            } else {
                Text("点一下你要配对的泵")
                    .font(.subheadline)

                VStack(spacing: 0) {
                    ForEach(model.discovered) { dev in
                        Button {
                            model.selectDevice(dev)
                        } label: {
                            deviceRow(dev)
                        }
                        .buttonStyle(.plain)
                        if dev.id != model.discovered.last?.id {
                            Divider().padding(.leading, 34)
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            }

            if let sel = model.selectedDevice, pickedInThisScan {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("已选：\(sel.name)").font(.caption)
                        .lineLimit(1).truncationMode(.middle)
                }
                if sel.serial == nil {
                    Callout(text: "这台的名字里读不到 6 位序列号。可能是固件版本不同，也可能根本不是泵——配对失败就换一台。", level: .warning)
                }
            }

            if model.showAllDevices {
                Callout(text: "诊断模式已打开，列表里混着其他蓝牙设备。配对请先在设置里关掉它。", level: .warning)
            }
        }
    }

    private func deviceRow(_ dev: EquilControllerModel.DiscoveredDevice) -> some View {
        let selected = model.selectedDevice?.id == dev.id
        return HStack(spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(dev.name)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(dev.matchesSerial ? .green : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(dev.serial.map { "SN \($0)" } ?? "名字里没有 SN")
                    .font(.caption2)
                    .foregroundStyle(dev.serial == nil ? .orange : .secondary)
            }
            Spacer(minLength: 6)
            Text("\(dev.rssi) dBm")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .contentShape(Rectangle())
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
    }

    // MARK: - 密码步

    private var passwordBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let sel = model.selectedDevice {
                VStack(spacing: 0) {
                    InfoRow(label: "设备", value: sel.name)
                    Divider()
                    InfoRow(label: "序列号", value: sel.serial ?? "未解析（用完整名称配对）",
                            level: sel.serial == nil ? .warning : .normal)
                }
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("配对密码（可选）").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(model.pairPassword.isEmpty ? "可选" : "\(model.pairPassword.count)/4")
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(model.pairPasswordValid ? .green : .secondary)
                }
                TextField("4 位，可留空", text: passwordBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .disabled(model.pairingState == .running)
            }

            Text("配对密码是可选的：给泵设一个 4 位密码（只能取 0-9 与 A-F），以后解绑这台泵也要用它，请记牢。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch model.pairingState {
            case .idle:
                EmptyView()
            case .running:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在配对…").font(.footnote.weight(.medium))
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            case .paired:
                Callout(text: "配对成功。下一步开始排气。", level: .normal)
            case .failed(let msg):
                Callout(text: "配对失败：\(msg)\n核对密码后重试；若反复被拒，泵可能已经绑定了别的控制器。", level: .critical)
            }

            Callout(text: "配对成功后，泵控制器将无法再控制这台泵。要再用泵控制器，必须在本 App 里正确解绑。密码请另行备份。", level: .critical)
        }
    }

    // MARK: - 底部

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if index > 0 {
                Button("上一步") { goBack() }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .disabled(model.pairingState == .running)
            }

            Button(primaryLabel) { advance() }
                .buttonStyle(.borderedProminent)
                .tint(primaryTint)
                .frame(maxWidth: .infinity)
                .disabled(!primaryEnabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var primaryLabel: String {
        guard let step = current else { return "完成" }
        switch step {
        case .fill:
            if model.busy {
                return model.primeCompleted ? "切换运行中…" : "排气中…"
            }
            return model.primeCompleted ? "下一步" : "开始排气"
        case .changeInsulin:
            return model.busy ? "退回中…" : "推杆退回"
        case .runMode:
            return model.runMode == .run ? "下一步" : "设为运行中"
        case .password:
            return model.pairingState == .running ? "配对中…" : "开始配对"
        case .confirm:
            return flow == .wizardPair ? "完成配对" : (flow == .wizardChange ? "完成换敷贴" : "完成")
        case .unpairConfirm:
            return model.busy ? "处理中…" : "解绑并退回推杆"
        default:
            return "下一步"
        }
    }

    private var primaryTint: Color {
        if current == .unpairConfirm { return .red }
        return .accentColor
    }

    private var primaryEnabled: Bool {
        guard let step = current else { return true }
        switch step {
        case .scanPick:
            // 必须本次扫描到并选中一台泵
            return pickedInThisScan && !model.busy
        case .password:
            // 密码合法 + 设备仍有效 + 没有正在跑的配对
            return model.canStartPairing && !model.busy && model.pairingState != .running
        case .fill:
            // 硬门槛：没配对成功不能排气
            return model.isPaired && !model.busy
        case .changeInsulin:
            return model.isPaired && !model.busy
        case .runMode:
            return !model.busy
        case .unpairConfirm:
            return !model.busy
        default:
            return true
        }
    }

    private func goBack() {
        guard model.pairingState != .running else { return }
        if current == .fill { model.stopScan() }
        index = max(0, index - 1)
    }

    private func advance() {
        guard let step = current else { return }

        switch step {
        case .changeInsulin:
            guard model.isPaired, !model.busy else { return }
            // 成功才前进；失败停在原页，状态栏写明原因，再点一次即重试。
            model.retractPlunger { ok in
                if ok { index += 1 }
            }

        case .scanPick:
            guard pickedInThisScan else { return }
            // 扫描到此为止：配对要独占 BLE 连接
            model.stopScan()
            model.persistIdentity()
            index += 1

        case .password:
            guard model.canStartPairing, model.pairingState != .running, !model.busy else { return }
            model.persistIdentity()
            // 不前进。等 pairingState 变成 .paired 再由 onChange 推进——
            // 失败就停在这一步，用户能看到失败原因并改密码重试。
            model.startPairing()

        case .fill:
            if model.busy { return }
            guard model.isPaired else { return }
            guard model.primeCompleted else {
                model.startPrime()
                return
            }
            // 排气完成即自动切运行中（CmdModelSet mode=1），成功后进确认页。
            // 这里无条件重发：泵可能在换敷贴期间被原厂控制器改回 STOP，
            // 沿用缓存就会出现「界面说运行中、实际命令被丢弃」。
            // 失败就停在这一页，statusLine 写明原因，再点一次即重试。
            model.setRunMode(resetTotal: true) { ok in
                if ok { index += 1 }
            }

        case .runMode:
            if model.runMode == .run {
                index += 1
            } else {
                // RUN 成功后就地回写状态，并直接前进，不用再点一次。
                // 向导这里的 RUN 一定是「新敷贴开始」，顺带清掉上一贴的起始量。
                model.setRunMode(resetTotal: true) { ok in
                    if ok { index += 1 }
                }
            }

        case .unpairConfirm:
            model.unpairAndRetract { _ in
                model.route = .overview
            }

        case .confirm:
            model.route = .overview

        default:
            index += 1
        }
    }
}

// MARK: - 步骤定义

enum WizardStepKind {
    case changeInsulin
    case assemble
    case scanPick
    case password
    case fill
    case runMode
    case confirm
    case unpairWarn
    case unpairConfirm

    var title: String {
        switch self {
        case .changeInsulin: return "更换储药器"
        case .assemble:      return "装配"
        case .scanPick:      return "找到你的泵"
        case .password:      return "输入配对密码"
        case .fill:          return "填充 / 排气"
        case .runMode:       return "设为运行中"
        case .confirm:       return "确认"
        case .unpairWarn:    return "解绑前必读"
        case .unpairConfirm: return "确认解绑"
        }
    }
}

// MARK: - 小组件

/// 步骤进度。对应 AAPS 的 StepProgressIndicator。
struct StepProgressIndicator: View {
    let current: Int
    let total: Int

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(1...max(total, 1), id: \.self) { i in
                    Capsule()
                        .fill(i <= current ? Color.accentColor : Color(.tertiarySystemFill))
                        .frame(height: 4)
                }
            }
            Text("第 \(min(current, total)) / \(total) 步")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

struct Bullet: View {
    let text: String
    init(_ t: String) { text = t }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 提示块。对应 AAPS 里的带色 Callout。
struct Callout: View {
    let text: String
    var level: StatusLevel = .warning

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: level.symbolName ?? "info.circle")
                .font(.footnote)
                .foregroundStyle(level.valueColor)
            Text(text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(level.containerBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
