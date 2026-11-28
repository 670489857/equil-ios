//
//  SafetyGuard.swift
//  EquilController
//
//  输注安全闸门 —— 所有向泵发送的剂量命令都必须先经过这里。
//
//  设计原则：
//   1. 绝对上限写死在代码里，不提供 UI 关闭入口。用户可调的是"更严格"，
//      不能把上限调到危险区间。
//   2. 校验失败一律 fail-closed：拿不准就拒绝，不放行。
//   3. 判定逻辑与 BLE 完全解耦，纯函数式，可单独测试。
//
//  ⚠️ 这不是医疗器械级的安全实现。它只能拦住"明显错误"（误触、手滑、重复提交），
//     拦不住协议错误、泵端异常、剂量计算错误。责任仍在操作者。
//

import Foundation

// MARK: - 请求与结论

/// 一次大剂量输注请求。所有会影响判断的上下文都要塞进来。
struct BolusRequest {
    let units: Double
    /// 泵报告的余量（U）。nil = 未读取过，此时按"未知"处理。
    var reservoirUnits: Int?
    /// 上面那个余量是多久以前读的（秒）。nil = 不知道/没读过。
    ///
    /// 泵只在回读时才更新余量，中间的基础率一直在消耗；读数越旧，
    /// 软件看到的数字越乐观。旧读数不能当"还剩这么多"用。
    var reservoirAge: TimeInterval?
    /// 泵当前是否处于 RUN 模式。nil = 未查询，按"未确认"处理。
    var pumpIsRunning: Bool?
    /// 泵侧允许的最大大剂量（U，写在泵固件里的那个）。nil = 未知，按"不额外限制"处理。
    /// 它可能比 App 的单次上限更小：此时真正能打出去的是两者中更小的那个。
    var pumpMaxBolus: Double?
    var now: Date = Date()
}

/// 闸门结论。三态，没有"警告后放行"这种模糊地带。
enum SafetyVerdict {
    /// 可以直接执行
    case allow
    /// 需要操作者二次确认（长按），原因会显示在确认页
    case confirm(reason: String)
    /// 直接拒绝，不提供申诉途径
    case deny(reason: String)

    var isDenied: Bool {
        if case .deny = self { return true }
        return false
    }

    /// 单行摘要，写审计日志用。
    var shortDescription: String {
        switch self {
        case .allow:                return "allow"
        case .confirm(let reason):  return "confirm: \(reason)"
        case .deny(let reason):     return "deny: \(reason)"
        }
    }
}

// MARK: - 闸门

final class SafetyGuard {

    // MARK: 不可逾越的绝对边界
    //
    // 这几个数字是最后一道墙。改它们需要改代码、重新编译、重新签名——
    // 而不是在设置页里点两下。请想清楚再动。

    /// 单次大剂量绝对上限（U）。成人常规大剂量很少超过 20U。
    static let absoluteMaxSingleDose: Double = 25.0
    /// 任意 60 分钟窗口内累计绝对上限（U）。
    static let absoluteMaxPerHour: Double = 40.0
    /// 两次输注之间的绝对最小间隔（秒）。
    static let absoluteMinInterval: TimeInterval = 60.0

    /// **泵的协议分辨率**：0.05 / 8 = 0.00625 U。
    ///
    /// CmdLargeBasalSet 里 `step = insulin / 0.05 * 8`，也就是一个 step 等于
    /// 1/160 U。这是硬件的表达下限，比它更细的剂量泵根本收不到。
    /// 精度校验用这个数，而不是 UI 步长——UI 步长只是「按一下加多少」，
    /// 不该成为「这个剂量泵能不能表达」的判据，否则用户输 0.075 会被
    /// 无理由拒绝（它明明是 12 个 step）。
    static let protocolResolution: Double = 0.00625

    /// 大剂量输入步长的可选值。0.025 是 AAPS 的默认值，0.05 更顺手。
    static let doseStepOptions: [Double] = [0.025, 0.05, 0.1]

    // MARK: 用户可调（只能调得更严格）

    /// 单次上限，默认 10U。取值范围 0.5 ... absoluteMaxSingleDose
    var maxSingleDose: Double {
        didSet { maxSingleDose = Self.clamp(maxSingleDose, 0.5, Self.absoluteMaxSingleDose) }
    }
    /// 每小时累计上限，默认 30U。
    var maxPerHour: Double {
        didSet { maxPerHour = Self.clamp(maxPerHour, 0.5, Self.absoluteMaxPerHour) }
    }
    /// 最小间隔，默认 60s（不低于绝对下限）。
    var minInterval: TimeInterval {
        didSet { minInterval = max(minInterval, Self.absoluteMinInterval) }
    }
    /// 余量至少保留多少 U 才允许输注，默认 10U。
    var reservoirReserve: Double

    /// 余量读数超过这个时长（秒）就算过期。默认 30 分钟。
    /// 泵只在回读时才更新余量，中间的基础率一直在消耗，旧数字只会偏多。
    var reservoirMaxAge: TimeInterval = 30 * 60

    /// 大于 0 时，超过这个剂量就必须长按确认。默认 0 = 每一笔都要长按。
    var alwaysConfirmAbove: Double

    /// 大剂量输入步长（+/- 按钮一次跳多少）。只影响输入体验，
    /// 不参与「这个剂量泵能不能表达」的判断——那是 protocolResolution 的事。
    var bolusStep: Double {
        didSet { bolusStep = Self.normalizeStep(bolusStep) }
    }

    // MARK: 状态

    private let storeKey = "safety.recentDoses.v1"
    private let settingsKey = "safety.settings.v1"
    private let defaults: UserDefaults

    /// 最近 60 分钟内的输注记录 (时间, 剂量)。跨启动持久化，防止重启绕过间隔限制。
    private(set) var recentDoses: [(at: Date, units: Double)] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let cfg = SafetyGuard.loadSettings(from: defaults)
        self.maxSingleDose = cfg.maxSingleDose
        self.maxPerHour = cfg.maxPerHour
        self.minInterval = cfg.minInterval
        self.reservoirReserve = cfg.reservoirReserve
        self.alwaysConfirmAbove = cfg.alwaysConfirmAbove
        self.bolusStep = cfg.bolusStep
        self.recentDoses = SafetyGuard.loadDoses(from: defaults)
        prune()
    }

    // MARK: 核心判定

    /// 评估一次输注请求。这是唯一的入口，UI 和执行层都走它。
    func evaluate(_ req: BolusRequest) -> SafetyVerdict {
        prune(now: req.now)

        // 1. 数值合法性 —— NaN、无穷、负数、零
        guard req.units.isFinite, req.units > 0 else {
            return .deny(reason: "剂量无效（必须是大于 0 的有限数值）")
        }

        // 2. 精度 —— 必须能被泵的 1/160 U 分辨率整除
        let steps = req.units / Self.protocolResolution
        if abs(steps - steps.rounded()) > 0.0001 {
            return .deny(reason: String(format: "剂量精度超出泵的分辨率（最小 %.5f U），已阻止", Self.protocolResolution))
        }

        // 3. 绝对单次上限 —— 不可申诉
        if req.units > Self.absoluteMaxSingleDose {
            return .deny(reason: String(format: "超过单次绝对上限 %.1f U，已阻止", Self.absoluteMaxSingleDose))
        }

        // 4. 用户单次上限 / 泵侧上限 —— 取两者中更小的
        //
        //   泵里那个「允许的最大大剂量值」是固件自己的限制，命令到了泵上，
        //   超过它一样会被拒（表现为超时 30 秒）。所以这里按两者较小值拦，
        //   不把「App 放行、泵拒绝」的情况留到 BLE 上。
        let pumpCap = req.pumpMaxBolus ?? .infinity
        let effectiveCap = min(maxSingleDose, pumpCap)
        if req.units > effectiveCap {
            if pumpCap < maxSingleDose {
                return .deny(reason: String(
                    format: "超过泵侧允许的最大大剂量 %.2f U（App 单次上限 %.2f U），泵会拒绝。先把「允许的最大大剂量值」调大并写入泵",
                    pumpCap, maxSingleDose
                ))
            }
            return .deny(reason: String(format: "超过你设定的单次上限 %.2f U，请先到设置里确认调整", maxSingleDose))
        }

        // 5. 最短间隔
        if let last = recentDoses.last {
            let gap = req.now.timeIntervalSince(last.at)
            if gap < minInterval {
                let remain = Int(ceil(minInterval - gap))
                return .deny(reason: "距上次输注仅 \(Int(gap)) 秒，需再等 \(remain) 秒")
            }
        }

        // 6. 每小时累计
        let hourAgo = req.now.addingTimeInterval(-3600)
        let sumLastHour = recentDoses
            .filter { $0.at > hourAgo }
            .reduce(0.0) { $0 + $1.units }
        if sumLastHour + req.units > maxPerHour {
            return .deny(reason: String(
                format: "本次 %.2f U 会超过每小时上限 %.1f U（已用 %.2f U）",
                req.units, maxPerHour, sumLastHour
            ))
        }

        // 7. 余量 —— 未知时要求确认，不做静默放行
        if let reservoir = req.reservoirUnits {
            let remainAfter = Double(reservoir) - req.units
            if remainAfter < 0 {
                return .deny(reason: String(format: "余量不足：泵内约 %d U，本次需要 %.2f U", reservoir, req.units))
            }
            if remainAfter < reservoirReserve {
                return .confirm(reason: String(
                    format: "输注后余量只剩 %.1f U（低于保留值 %.1f U），请确认是否继续",
                    remainAfter, reservoirReserve
                ))
            }
            // 读数太旧：泵只在回读时刷新余量，两次回读之间的基础率消耗是看不见的，
            // 所以旧数字只会偏多。仍按它算 deny，但"看起来够"时必须让人再确认一次。
            if let age = req.reservoirAge, age > reservoirMaxAge {
                return .confirm(reason: String(
                    format: "余量是 %d 分钟前的读数，泵里实际更少。建议先点「刷新」回读一次再输注",
                    Int(age / 60)
                ))
            }
        } else {
            return .confirm(reason: "尚未读取泵内余量。建议先点「查询余量」，确认后再输注")
        }

        // 8. 运行模式 —— 非 RUN 时泵会静默丢弃命令，白等 30 秒
        switch req.pumpIsRunning {
        case .some(false):
            return .confirm(reason: "泵当前不在 RUN 模式，命令可能被静默丢弃。建议先点「设为运行中」")
        case .none:
            return .confirm(reason: "尚未确认泵的运行模式。若不在 RUN 模式，本次命令会超时失败")
        case .some(true):
            break
        }

        // 9. 超过阈值必须二次确认
        if req.units > alwaysConfirmAbove {
            return .confirm(reason: String(format: "本次 %.2f U 超过确认阈值 %.2f U", req.units, alwaysConfirmAbove))
        }

        return .allow
    }

    // MARK: 记账

    /// 输注成功后登记。只有泵确实接受了才调用 —— 失败的命令不占额度，
    /// 否则一次超时就会把用户锁在门外。
    func recordBolus(units: Double, at date: Date = Date()) {
        recentDoses.append((at: date, units: units))
        prune(now: date)
        persistDoses()
    }

    /// 清除全部记录（换泵、误操作后手工重置用）。
    func resetHistory() {
        recentDoses.removeAll()
        persistDoses()
    }

    /// 当前窗口已用量，给 UI 显示。
    func usedLastHour(now: Date = Date()) -> Double {
        let hourAgo = now.addingTimeInterval(-3600)
        return recentDoses.filter { $0.at > hourAgo }.reduce(0.0) { $0 + $1.units }
    }

    /// 距离下一次可输注还差多少秒。0 表示现在就可以。
    func cooldownRemaining(now: Date = Date()) -> TimeInterval {
        guard let last = recentDoses.last else { return 0 }
        let elapsed = now.timeIntervalSince(last.at)
        return max(0, minInterval - elapsed)
    }

    // MARK: 配置持久化

    struct Settings {
        /// 默认 25 U（上限值）。日常仍建议按自己单次最大剂量下调。
        var maxSingleDose: Double = 10
        var maxPerHour: Double = 30
        var minInterval: TimeInterval = 60
        var reservoirReserve: Double = 10
        /// 默认 0：任何大于 0 的剂量都要长按确认。见不得血的日子里，烦一点没关系。
        var alwaysConfirmAbove: Double = 0
        /// UI 步长，默认 0.025（与 AAPS 一致）。
        var bolusStep: Double = 0.025
    }

    func persistSettings() {
        let dict: [String: Double] = [
            "maxSingleDose": maxSingleDose,
            "maxPerHour": maxPerHour,
            "minInterval": minInterval,
            "reservoirReserve": reservoirReserve,
            "alwaysConfirmAbove": alwaysConfirmAbove,
            "bolusStep": bolusStep,
        ]
        defaults.set(dict, forKey: settingsKey)
    }

    static func loadSettings(from defaults: UserDefaults) -> Settings {
        var s = Settings()
        guard let dict = defaults.dictionary(forKey: "safety.settings.v1") as? [String: Double] else {
            return s
        }
        if let v = dict["maxSingleDose"] { s.maxSingleDose = clamp(v, 0.5, absoluteMaxSingleDose) }
        if let v = dict["maxPerHour"] { s.maxPerHour = clamp(v, 0.5, absoluteMaxPerHour) }
        if let v = dict["minInterval"] { s.minInterval = max(v, absoluteMinInterval) }
        if let v = dict["reservoirReserve"] { s.reservoirReserve = max(0, v) }
        if let v = dict["alwaysConfirmAbove"] { s.alwaysConfirmAbove = max(0, v) }
        if let v = dict["bolusStep"] { s.bolusStep = normalizeStep(v) }
        return s
    }

    /// 把任意输入吸附到最近的合法步长。0.03 会被拉成 0.025，0.06 拉成 0.05。
    static func normalizeStep(_ v: Double) -> Double {
        guard v.isFinite, v > 0 else { return 0.025 }
        return doseStepOptions.min(by: { abs($0 - v) < abs($1 - v) }) ?? 0.025
    }

    // MARK: 私有

    /// 丢掉 60 分钟以前的记录。
    private func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-3600)
        recentDoses.removeAll { $0.at < cutoff }
    }

    private func persistDoses() {
        let raw = recentDoses.map { [$0.at.timeIntervalSince1970, $0.units] }
        defaults.set(raw, forKey: storeKey)
    }

    private static func loadDoses(from defaults: UserDefaults) -> [(at: Date, units: Double)] {
        guard let raw = defaults.array(forKey: "safety.recentDoses.v1") as? [[Double]] else { return [] }
        return raw.compactMap { pair in
            guard pair.count == 2 else { return nil }
            return (at: Date(timeIntervalSince1970: pair[0]), units: pair[1])
        }
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        guard v.isFinite else { return lo }
        return min(max(v, lo), hi)
    }
}
