//
//  SettingsView.swift
//  EquilController
//
//  这一页对应 Equil 的「参数设置」：白卡片 + 标题 + 范围小字 + 值药丸/输入框，
//  右上角一个「写入」把参数下发到泵。
//
//  两类参数放在同一页，但必须分清：
//    · 泵侧参数（报警方式、最大大剂量、最大基础率、低药量阈值）
//      —— 写在泵的存储里，掉电还在，靠 CmdAlarmSet / CmdSettingSet 下发。
//    · App 侧参数（剂量安全）
//      —— 只活在这台手机上，管的是「这个 App 允许发多大的量」。
//  前者不能比后者宽松，否则泵会直接拒绝超限命令，所以写入前会互相校验。
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: EquilControllerModel
    @Environment(\.dismiss) private var dismiss

    // 泵侧
    @State private var alarmMode: EquilAlarmMode = .mute
    @State private var maxBolusText: String = "10"
    @State private var maxBasalText: String = "5.0"
    @State private var lowReservoirText: String = "10"
    /// 大剂量速度。这个值不下发到泵，只决定每次大剂量命令里填的 stepTime。
    @State private var bolusSpeed: BolusSpeed = .fast

    // App 侧
    @State private var maxSingle: Double = 10
    @State private var maxPerHour: Double = 30
    @State private var minInterval: Double = 60
    @State private var reserve: Double = 10
    @State private var bolusStep: Double = 0.025

    @State private var tempRate: String = "0.5"
    @State private var tempDuration: String = "30"

    @State private var extUnits: String = "1"
    @State private var extMinutes: String = "60"
    @State private var confirmCancelExtended = false

    var body: some View {
        NavigationStack {
            ScrollView {
                // 顺序固定：大剂量、临时基础率、方波在最上面 —— 这三张是日常真正会用的，
                // 打开设置第一屏就要能点到，不用往下翻。
                // 大剂量原来占概览页第一个方格，按反馈挪进来并排在临时基础率前面。
                VStack(spacing: 12) {
                    bolusCard
                    tempBasalCard
                    extendedBolusCard

                    alarmCard
                    maxBolusCard
                    bolusRateCard
                    maxBasalCard
                    lowReservoirCard

                    safetyCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .background(AapsUI.background)
            .navigationTitle("参数设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") {
                        persistAppSide()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        commitPumpSide()
                        model.writePumpSettings()
                    } label: {
                        Text("写入")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(model.isPaired && !model.busy ? AapsUI.accent : Color.gray.opacity(0.45))
                            .clipShape(Capsule())
                    }
                    .disabled(model.busy || !model.isPaired)
                }
            }
            .overlay(alignment: .bottom) {
                if model.busy {
                    writeProgress
                }
            }
            .onAppear(perform: load)
            // 方波/大剂量从设置页发起时，确认页必须由设置页自己呈现：
            // 设置页本身已经是一个 sheet，再让 ContentView 去 present 会撞车
            // （同一个父视图不能同时 present 两个 sheet，确认页会弹不出来）。
            .sheet(isPresented: settingsBolusConfirmBinding) {
                if let units = model.pendingBolus {
                    BolusConfirmView(
                        units: units,
                        reason: model.pendingReason,
                        extendedMinutes: model.pendingExtendedMinutes,
                        reservoirUnits: model.reservoirUnits,
                        maxSingleDose: min(model.safety.maxSingleDose, model.pumpConfig.maxBolus),
                        maxPerHour: model.safety.maxPerHour,
                        usedLastHour: model.safety.usedLastHour(),
                        onConfirm: { model.confirmBolus() },
                        onCancel: { model.cancelBolus() }
                    )
                }
            }
            .alert("取消方波？", isPresented: $confirmCancelExtended) {
                Button("取消方波", role: .destructive) { model.cancelExtendedBolus() }
                Button("保留", role: .cancel) {}
            } message: {
                Text("泵会立刻停止这条方波剩余的量。已经推出去的部分不会退回。")
            }
        }
    }

    // MARK: - 大剂量

    /// 大剂量卡片。
    ///
    /// 原本是概览页第一个方格，点开一个独立的输入页。按反馈挪到这里，
    /// 版式与「临时基础率 / 方波」一致：一个输入框 + 一个按钮 + 当前值，
    /// 少一次弹窗，也不用再处理 sheet 套 sheet。
    /// 确认页仍由设置页自己 present（`settingsBolusConfirmBinding`），
    /// 闸门、审计、二次确认与原来完全同一条路径。
    private var bolusCard: some View {
        AapsCard {
            VStack(alignment: .leading, spacing: 12) {
                CardTitle(title: "大剂量")
                HStack(spacing: 10) {
                    FieldShell {
                        TextField("0.05", text: $model.bolusUnits)
                            .keyboardType(.decimalPad)
                    }
                    Text("U").font(.system(size: 14)).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    smallButton("输注",
                                enabled: model.isPaired && model.activationCompleted) {
                        sendBolusFromCard()
                    }
                }
                Text(bolusHint)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if let last = model.lastBolus {
                    Text(String(format: "最近一次 %.2f U（%@）", last.units, Self.timeText(last.at)))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                // 输注中：这个 sheet 关掉之后首页也有同一块，这里先给一个近处的出口。
                if let d = model.bolusDelivery {
                    let now = model.bolusTick
                    HStack(spacing: 10) {
                        Text(String(format: "正在输注 %.2f / %.2f U · 剩余约 %d 秒",
                                    d.delivered(at: now), d.units,
                                    Int(d.remaining(at: now).rounded())))
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button {
                            model.stopBolusDelivery()
                        } label: {
                            Text("停止输注")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.busy)
                    }
                }
                if model.isPaired && !model.activationCompleted {
                    Text("泵还没完成初始化（没进过运行中），泵会丢弃输注命令。")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    /// 步长 + 输注速率 + 预计耗时。速度调到 12 U/min 时 5 U 只要 25 秒，
    /// 而标准 1.5 U/min 要 200 秒 —— 点之前就该看见。
    private var bolusHint: String {
        let speed = model.pumpConfig.bolusSpeed
        let step = Self.trim(model.safety.bolusStep)
        let units = Double(model.bolusUnits.replacingOccurrences(of: "，", with: ".")) ?? 0
        guard units > 0 else { return "步长 \(step) U · 输注速率 \(speed.label)" }
        let seconds = max(1, Int((units * Double(speed.secondsPerUnit)).rounded()))
        return "步长 \(step) U · 输注速率 \(speed.label) · 预计 \(seconds) 秒"
    }

    private func sendBolusFromCard() {
        let raw = model.bolusUnits
            .replacingOccurrences(of: "，", with: ".")
            .replacingOccurrences(of: ",", with: ".")
        guard let units = Double(raw), units > 0 else {
            model.statusLine = "大剂量：数值无效"
            return
        }
        model.sendBolus(units: units)
    }

    // MARK: - 泵侧参数卡片

    private var alarmCard: some View {
        AapsCard {
            HStack {
                CardTitle(title: "报警方式")
                Spacer(minLength: 12)
                Menu {
                    ForEach(EquilAlarmMode.allCases) { mode in
                        Button(mode.label) { alarmMode = mode }
                    }
                } label: {
                    ValuePill(text: alarmMode.label, showsChevron: true)
                }
            }
        }
    }

    private var maxBolusCard: some View {
        AapsCard {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(title: "允许的最大大剂量值 [U]", caption: "1 - 25 U")
                FieldShell {
                    TextField("10", text: $maxBolusText)
                        .keyboardType(.decimalPad)
                }
            }
        }
    }

    private var bolusRateCard: some View {
        AapsCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    CardTitle(title: "大剂量输注速率 [U/min]")
                    Spacer(minLength: 12)
                    Menu {
                        ForEach(BolusSpeed.allCases) { s in
                            Button {
                                bolusSpeed = s
                                // 速度不影响泵的设置，改完立即生效并落盘，
                                // 不必等「写入」（那个按钮只下发给泵）。
                                model.pumpConfig.bolusSpeed = s
                                model.persistPumpConfig()
                            } label: {
                                Text("\(s.label)　\(s.detail)")
                            }
                        }
                    } label: {
                        ValuePill(text: bolusSpeed.label, showsChevron: true)
                    }
                }
            }
        }
    }

    private var maxBasalCard: some View {
        AapsCard {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(title: "泵的最大基础率 [U/H]", caption: "0.5 - 15.0 U/H")
                FieldShell {
                    TextField("5.0", text: $maxBasalText)
                        .keyboardType(.decimalPad)
                }
            }
        }
    }

    private var lowReservoirCard: some View {
        AapsCard {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(title: "低药量报警阈值 [U]", caption: "10 - 50 U")
                FieldShell {
                    TextField("10", text: $lowReservoirText)
                        .keyboardType(.decimalPad)
                }
            }
        }
    }

    // MARK: - App 侧安全闸门

    private var safetyCard: some View {
        AapsCard {
            VStack(spacing: 14) {
                sliderRow(title: "单次上限",
                          value: String(format: "%.2f U", maxSingle),
                          binding: $maxSingle,
                          range: 0.5...SafetyGuard.absoluteMaxSingleDose,
                          step: 0.25)
                sliderRow(title: "每小时累计上限",
                          value: String(format: "%.1f U", maxPerHour),
                          binding: $maxPerHour,
                          range: 0.5...SafetyGuard.absoluteMaxPerHour,
                          step: 0.5)
                sliderRow(title: "最短间隔",
                          value: "\(Int(minInterval)) 秒",
                          binding: $minInterval,
                          range: SafetyGuard.absoluteMinInterval...600,
                          step: 30)
                sliderRow(title: "余量保留下限",
                          value: String(format: "%.0f U", reserve),
                          binding: $reserve,
                          range: 0...50,
                          step: 1)
            }
        }
    }

    private func sliderRow(title: String, value: String,
                           binding: Binding<Double>,
                           range: ClosedRange<Double>, step: Double) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(title).font(.system(size: 16))
                Spacer()
                Text(value)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: binding, in: range, step: step)
        }
    }

    // MARK: - 临时基础率 / 运行模式

    private var tempBasalCard: some View {
        AapsCard {
            VStack(alignment: .leading, spacing: 12) {
                CardTitle(title: "临时基础率")
                HStack(spacing: 10) {
                    FieldShell {
                        TextField("0.5", text: $tempRate)
                            .keyboardType(.decimalPad)
                    }
                    Text("U/h").font(.system(size: 14)).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    FieldShell {
                        TextField("30", text: $tempDuration)
                            .keyboardType(.numberPad)
                    }
                    Text("分钟").font(.system(size: 14)).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    pumpButton("设置") {
                        model.tempRate = tempRate
                        model.tempDuration = tempDuration
                        model.setTempBasal()
                    }
                    pumpButton("查询") { model.queryTempBasal() }
                    pumpButton("取消", tint: .red) { model.cancelTempBasal() }
                }
                if let s = model.tempBasalSummary {
                    Text(model.tempBasalPendingVerify ? "已下发：\(s)（回读确认中…）" : "当前：\(s)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Text("当前：无")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                if model.runMode != .run && model.isPaired {
                    Text("泵只在「运行中」模式下接受临时基础率，现在是「\(model.runMode.displayName)」。")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    /// 方波（延长波）卡片。版式与「临时基础率」保持一致：两个输入框 + 三个按钮 + 当前值。
    ///
    /// 方波与临时基础率的区别要说清楚：临时基础率改的是「每小时多少 U」，
    /// 方波是把「总量多少 U」摊到一段时间里匀速推完。
    /// 泵侧没有「查方波」的命令，所以「查询」只能刷新本机记账并把余量重新回读一次。
    private var extendedBolusCard: some View {
        AapsCard {
            VStack(alignment: .leading, spacing: 12) {
                CardTitle(title: "方波大剂量")
                HStack(spacing: 10) {
                    FieldShell {
                        TextField("1", text: $extUnits)
                            .keyboardType(.decimalPad)
                    }
                    Text("U").font(.system(size: 14)).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    FieldShell {
                        TextField("60", text: $extMinutes)
                            .keyboardType(.numberPad)
                    }
                    Text("分钟").font(.system(size: 14)).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    pumpButton("设置") { sendExtended() }
                    pumpButton("查询") { model.scheduleReservoirRefresh(after: 0.5, reason: "方波查询") }
                    pumpButton("取消", tint: .red) { confirmCancelExtended = true }
                }
                Text(extendedStatusText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("总剂量在时长内匀速推完，不是一次打完。时长 1…480 分钟。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var extendedStatusText: String {
        guard let end = model.extendedBolusEnd, end > Date() else { return "当前：无" }
        let mins = max(1, Int(end.timeIntervalSinceNow / 60) + 1)
        return String(format: "当前：方波 %.2f U，剩 %d 分钟（至 %@）",
                      model.extendedBolusUnits, mins, Self.timeText(end))
    }

    /// 方波与我们自己的大剂量走同一个入口，闸门、审计、确认页都是同一套。
    private func sendExtended() {
        let units = Double(extUnits.replacingOccurrences(of: ",", with: ".")) ?? 0
        let minutes = Int(extMinutes.trimmingCharacters(in: .whitespaces)) ?? 0
        guard units > 0 else {
            model.statusLine = "方波：剂量无效"
            return
        }
        guard EquilControllerModel.extendedMinutesRange.contains(minutes) else {
            model.statusLine = "方波：时长要在 1…480 分钟之间"
            return
        }
        model.sendBolus(units: units, extendedMinutes: minutes)
    }

    private func smallButton(_ title: String, tint: Color = AapsUI.accent,
                             enabled: Bool? = nil,
                             action: @escaping () -> Void) -> some View {
        let on = (enabled ?? true) && !model.busy
        return Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(tint.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!on)
        .opacity(on ? 1 : 0.45)
    }

    /// 需要已配对才能点的按钮。
    private func pumpButton(_ title: String, tint: Color = AapsUI.accent,
                            action: @escaping () -> Void) -> some View {
        smallButton(title, tint: tint, enabled: model.isPaired, action: action)
    }

    private var writeProgress: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(model.statusLine)
                .font(.footnote)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .clipShape(Capsule())
        .padding(.bottom, 16)
    }

    // MARK: - 读写

    private var settingsBolusConfirmBinding: Binding<Bool> {
        Binding(
            get: { model.pendingBolus != nil },
            set: { presented in if !presented { model.cancelBolus() } }
        )
    }

    private func load() {
        alarmMode = model.pumpConfig.alarmMode
        maxBolusText = Self.trim(model.pumpConfig.maxBolus)
        maxBasalText = Self.trim(model.pumpConfig.maxBasal)
        lowReservoirText = Self.trim(model.pumpConfig.lowReservoir)
        bolusSpeed = model.pumpConfig.bolusSpeed

        maxSingle = model.safety.maxSingleDose
        maxPerHour = model.safety.maxPerHour
        minInterval = model.safety.minInterval
        reserve = model.safety.reservoirReserve
        bolusStep = model.safety.bolusStep

        tempRate = model.tempRate
        tempDuration = model.tempDuration
    }

    /// 把输入框里的字符串收进 pumpConfig。范围外就地夹住，不静默丢弃。
    private func commitPumpSide() {
        // 用 var 复制再逐字段赋值，而不是重新构造 PumpConfig(...)：
        // 后者每加一个字段就要记得在调用处补一个参数，漏了就悄悄回默认值。
        var cfg = model.pumpConfig
        cfg.alarmModeRaw = alarmMode.rawValue
        cfg.maxBolus = clamp(Double(maxBolusText) ?? model.pumpConfig.maxBolus,
                             PumpConfig.maxBolusRange)
        cfg.maxBasal = clamp(Double(maxBasalText) ?? model.pumpConfig.maxBasal,
                             PumpConfig.maxBasalRange)
        cfg.lowReservoir = clamp(Double(lowReservoirText) ?? model.pumpConfig.lowReservoir,
                                 PumpConfig.lowReservoirRange)
        cfg.bolusSpeed = bolusSpeed
        cfg = cfg.sanitized()
        model.pumpConfig = cfg
        // 输入框回写规范化后的值，让人看到「被夹到哪了」
        maxBolusText = Self.trim(cfg.maxBolus)
        maxBasalText = Self.trim(cfg.maxBasal)
        lowReservoirText = Self.trim(cfg.lowReservoir)
        bolusSpeed = cfg.bolusSpeed
        model.persistPumpConfig()
    }

    private func persistAppSide() {
        model.safety.maxSingleDose = maxSingle
        model.safety.maxPerHour = maxPerHour
        model.safety.minInterval = minInterval
        model.safety.reservoirReserve = reserve
        model.safety.bolusStep = bolusStep
        model.safety.persistSettings()
        model.persistIdentity()
    }

    private func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double {
        guard v.isFinite else { return r.lowerBound }
        return min(max(v, r.lowerBound), r.upperBound)
    }

    /// 10.0 → "10"，5.5 → "5.5"
    private static func trim(_ v: Double) -> String {
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    private static func timeText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }
}

// MARK: - 实时日志

struct LogView: View {
    @ObservedObject var model: EquilControllerModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.logLines.enumerated()), id: \.offset) { idx, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(idx)
                    }
                }
                .padding(.horizontal, 12)
            }
            .onChange(of: model.logLines.count) { _, _ in
                if let last = model.logLines.indices.last {
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
        .navigationTitle("实时日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("清空", role: .destructive) { model.clearLog() }
            }
        }
    }
}
