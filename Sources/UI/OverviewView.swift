//
//  OverviewView.swift
//  EquilController
//
//  版式对齐 Equil 的参数页/概览页（AAPS 的风格）：
//    1. 可选状态横幅（只有异常时出现，正常时保持页面干净）
//    2. 一张表：9 行 label / value，两列居中，中间一条竖线
//    3. 泵的示意图
//    4. 六个方格按钮（未配对：配对 / 设置；已配对：大剂量 / 暂停、换敷贴 / 历史、刷新 / 解绑）
//    5. 未配对时底部一行引导语（已配对不显示，状态由顶部横幅承担）
//
//  数据来源与 AAPS 的 EquilOverviewViewModel.buildUiState() 一一对应，
//  读不到的一律显示「-」，不用 0 冒充。
//

import SwiftUI

struct OverviewView: View {
    @ObservedObject var model: EquilControllerModel

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let banner = bannerContent {
                    bannerView(banner)
                }

                infoTable

                bolusProgressCard

                PumpIllustration()

                actionTiles

                hintText

            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 18)
        }
        .background(AapsUI.background)
        // 右上角齿轮已去掉：设置改成第一排第三个方格，
        // 手指不用往上够（单手、戴手套都好点）。
    }

    // MARK: - 状态横幅

    private struct Banner {
        var text: String
        var level: StatusLevel
    }

    /// 顺序照抄 AAPS buildStatusBanner()：未激活 > STOP > SUSPEND。
    private var bannerContent: Banner? {
        if !model.isPaired {
            if model.selectedDevice == nil {
                return Banner(text: "还没连接泵。点下面「配对 EQUIL」，扫描附近的泵并选中，再输入这台泵的 4 位配对密码。",
                              level: .warning)
            }
            return Banner(text: "已选中 \(model.selectedDeviceLabel ?? "泵")，点「配对 EQUIL」继续。", level: .warning)
        }
        if !model.activationCompleted {
            return Banner(text: "尚未完成初始化：泵未进入运行中状态，输注命令会被静默丢弃", level: .warning)
        }
        switch model.runMode {
        case .stop:     return Banner(text: "泵已停止输注（STOP）", level: .critical)
        case .suspend:  return Banner(text: "泵已暂停输注（SUSPEND）", level: .warning)
        case .run, .unknown: return nil
        }
    }

    private func bannerView(_ banner: Banner) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if let symbol = banner.level.symbolName {
                Image(systemName: symbol)
                    .font(.footnote)
                    .foregroundStyle(banner.level.valueColor)
            }
            Text(banner.text)
                .font(.subheadline)
                .foregroundStyle(banner.level == .critical ? Color.red : (banner.level == .warning ? Color.orange : Color.primary))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(banner.level.containerBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: - 表格

    private struct Row {
        var label: String
        var value: String
        var level: StatusLevel = .unspecified
        /// 固定值颜色，优先于 level。运行模式用它保证「-」也是绿色。
        var valueTint: Color? = nil
    }

    private var infoTable: some View {
        let items = rows
        // 标签列占 40%（按对照图量出来 0.401）。用 GeometryReader 拿真实宽度，
        // 而不是写死点数：Pro Max 和 mini 差 60pt，写死会两边都不像。
        return GeometryReader { geo in
            let labelWidth = (geo.size.width * 0.40).rounded()
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, row in
                    TableRow(label: row.label,
                             value: row.value,
                             level: row.level,
                             valueTint: row.valueTint,
                             labelWidth: labelWidth,
                             showsBottomLine: index < items.count - 1)
                }
            }
        }
        .frame(height: TableRow.height * CGFloat(items.count))
        .background(AapsUI.card)
        .clipShape(RoundedRectangle(cornerRadius: AapsUI.corner, style: .continuous))
    }

    /// 行序与 AAPS 概览一致：SN → 固件 → 模式 → 连接 → 电池 → 余量 →
    /// 基础率 → 临时基础率 → 总输送量 → 上次注射。
    private var rows: [Row] {
        var out: [Row] = []

        out.append(Row(label: "序列号", value: dash(model.serialNumber)))
        out.append(Row(label: "固件版本", value: dash(model.firmwareVersion)))

        // 文案与对照图一致：RUN 显示「运行中」，绿色；异常态保留橙/红。
        let (modeText, modeLevel): (String, StatusLevel) = {
            guard model.isPaired else { return ("-", .unspecified) }
            guard model.activationCompleted else { return ("未初始化", .warning) }
            switch model.runMode {
            case .run:     return ("运行中", .success)
            case .suspend: return ("已暂停", .warning)
            case .stop:    return ("已停止", .critical)
            case .unknown: return ("-", .unspecified)
            }
        }()
        // 运行模式这一行的值恒为绿色：显示「运行中」是绿字，没有读数时那个「-」
        // 也保持绿字（以前走 .unspecified → 黑字，看着像没状态）。
        // 只有「已暂停 / 已停止 / 未初始化」用橙 / 红 —— 传 nil 让它走 level 色。
        let modeTint: Color? = {
            switch modeLevel {
            case .warning, .critical: return nil
            default: return .green
            }
        }()
        out.append(Row(label: "运行模式", value: modeText,
                       level: modeLevel, valueTint: modeTint))

        out.append(Row(label: "最后连接", value: Self.dateTimeText(model.lastDataTime)))
        out.append(Row(label: "电池", value: model.batteryPercent.map { "\($0)%" } ?? "-",
                       level: batteryLevel(model.batteryPercent)))
        out.append(Row(label: "胰岛素储药器", value: reservoirText,
                       level: reservoirLevel(model.reservoirUnits)))
        out.append(Row(label: "基础速率",
                       value: model.baseBasalRate.map { String(format: "%.3f U/h", $0) } ?? "-"))
        out.append(Row(label: "临时基础速率", value: model.tempBasalSummary ?? "-",
                       level: model.tempBasalSummary == nil ? .unspecified : .normal))
        // 总输送量 = 起始量 − 当前余量，与 AAPS `EquilOverviewViewModel` 同口径。
        // 两边都是泵回报的整数单位，所以只精确到 1 U；起始量未知时显示「-」。
        out.append(Row(label: "总输送量",
                       value: model.totalDeliveredUnits.map { "\($0) U" } ?? "-"))


        if let bolus = model.lastBolus {
            out.append(Row(label: "最后一次注射",
                           value: String(format: "%.2f U · %@", bolus.units, Self.timeText(bolus.at))))
        } else {
            out.append(Row(label: "最后一次注射", value: "-"))
        }

        // 正在跑的方波：泵没有「查方波」的命令，这行是本机记账，
        // 结束时刻过了就自动消失。
        if let end = model.extendedBolusEnd, end > Date() {
            let mins = max(1, Int(end.timeIntervalSinceNow / 60) + 1)
            out.append(Row(label: "方波进行中",
                           value: String(format: "%.2f U", model.extendedBolusUnits) + " · 剩 \(mins) 分钟",
                           level: .normal))
        }

        return out
    }

    /// 余量一栏：泵只给整数单位，所以显示「12 U · 3 分钟前」；
    /// 超过 20 分钟没回读就加 ≈，提示它只是上次的读数。
    private var reservoirText: String {
        guard let u = model.reservoirUnits else { return "-" }
        let mark = model.reservoirIsStale ? "≈" : ""
        if let age = model.reservoirAgeShort {
            return "\(mark)\(u) U · \(age)"
        }
        return "\(mark)\(u) U"
    }

    private func dash(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "-" }
        return s
    }

    private func batteryLevel(_ p: Int?) -> StatusLevel {
        guard let p else { return .unspecified }
        if p <= 10 { return .critical }
        if p <= 25 { return .warning }
        return .unspecified
    }

    private func reservoirLevel(_ u: Int?) -> StatusLevel {
        guard let u else { return .unspecified }
        if u <= 5 { return .critical }
        if u <= 20 { return .warning }
        return .unspecified
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        // 月、日补零：2026/11/09 16:04:10（2026/11/9 这种单数字写法看着散）
        let f = DateFormatter(); f.dateFormat = "yyyy/MM/dd HH:mm:ss"; return f
    }()

    private static func timeText(_ d: Date?) -> String {
        guard let d else { return "-" }
        return clockFormatter.string(from: d)
    }

    /// 「最后连接」用带年月日的写法（2026/11/09 13:50:11），与对照图一致；
    /// 只看时分秒的话，隔夜之后再打开分不清是今天还是昨天。
    private static func dateTimeText(_ d: Date?) -> String {
        guard let d else { return "-" }
        return dateTimeFormatter.string(from: d)
    }

    // MARK: - 大剂量进度

    /// 泵 ACK 之后、推完之前显示。这段时间连接已经断开，泵自己还在推，
    /// 界面上别的地方不会变 —— 不给这块，用户根本看不出还在输注，更谈不上中途停。
    @ViewBuilder
    private var bolusProgressCard: some View {
        if let d = model.bolusDelivery {
            let now = model.bolusTick
            let delivered = d.delivered(at: now)
            let remaining = d.remaining(at: now)
            let fraction = d.units > 0 ? min(1, delivered / d.units) : 0

            AapsCard {
                VStack(spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("正在输注")
                            .font(.system(size: 16, weight: .semibold))
                        Spacer(minLength: 8)
                        Text(String(format: "%.2f / %.2f U", delivered, d.units))
                            .font(.system(size: 16))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    ProgressView(value: fraction)
                        .tint(AapsUI.accent)

                    HStack {
                        Text(String(format: "剩余约 %d 秒", Int(remaining.rounded())))
                            .font(.system(size: 13))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button {
                            model.stopBolusDelivery()
                        } label: {
                            Text("停止输注")
                                .font(.system(size: 15, weight: .semibold))
                                .padding(.horizontal, 18)
                                .frame(height: 40)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.red, lineWidth: 1.5)
                                )
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.busy)
                    }
                }
            }
        }
    }

    // MARK: - 大按钮

    @ViewBuilder
    private var actionTiles: some View {
        if model.isPaired {
            // 2 行 × 3 列。六个动作一样大，热区一致；原来「刷新 / 解绑」是小字按钮，
            // 又窄又靠底，单手不好点。
            // 顺序（按用户指定）：
            //   换敷贴 · 运行模式 · 设置
            //   历史   · 刷新     · 解绑
            // 大剂量挪进设置页第一栏（排在临时基础率前面），这里不再占格子。
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                      spacing: 10) {
                TileAction(title: "换敷贴", systemImage: "arrow.triangle.2.circlepath",
                           tint: AapsUI.accent, enabled: !model.busy) {
                    model.route = .wizardChange
                }
                switch model.runMode {
                case .suspend:
                    TileAction(title: "恢复输注", systemImage: "play.fill",
                               tint: .green, enabled: !model.busy) {
                        model.setRunMode()
                    }
                case .stop, .unknown:
                    TileAction(title: "设为运行中", systemImage: "play.fill",
                               tint: .green, enabled: !model.busy) {
                        model.setRunMode()
                    }
                case .run:
                    TileAction(title: "暂停输注", systemImage: "pause.fill",
                               tint: .orange, enabled: !model.busy) {
                        model.suspendPump()
                    }
                }
                TileAction(title: "设置", systemImage: "gearshape",
                           tint: AapsUI.accent, enabled: !model.busy) {
                    model.showSettings = true
                }
                TileAction(title: "历史", systemImage: "clock.arrow.circlepath",
                           tint: AapsUI.accent, enabled: !model.busy) {
                    model.route = .history
                }
                TileAction(title: "刷新", systemImage: "arrow.clockwise",
                           tint: AapsUI.accent, enabled: !model.busy) {
                    model.refreshStatus()
                }
                TileAction(title: "解绑", systemImage: "trash",
                           tint: .red, enabled: !model.busy) {
                    model.route = .wizardUnpair
                }
            }
        } else {
            HStack(spacing: 10) {
                TileAction(title: "配对 EQUIL", systemImage: "link",
                           tint: .orange, enabled: !model.busy) {
                    model.route = .wizardPair
                }
                TileAction(title: "设置", systemImage: "gearshape",
                           tint: .green, enabled: !model.busy) {
                    model.showSettings = true
                }
            }
        }
    }

    // MARK: - 底部提示

    /// 只保留未配对时的引导语。
    /// 已配对时底部不再显示任何提示：STOP / SUSPEND / 未初始化这些状态
    /// 顶部横幅已经用橙红块讲清楚了，底部再来一行只会挤版面。
    @ViewBuilder
    private var hintText: some View {
        if !model.isPaired {
            Text("请选择「配对 EQUIL」开始添加 Equil 泵。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
    }
}
