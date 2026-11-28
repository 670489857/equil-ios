//
//  PumpConfig.swift
//  EquilController
//
//  泵侧参数（不是 App 侧的安全闸门）。
//
//  这些值写进泵里，掉电后仍然保留；App 侧安全闸门是另一套（SafetyGuard），
//  两者关系是「泵侧上限 ≥ App 侧上限」，否则泵会直接拒绝超限的大剂量。
//
//  字段对应 AAPS 的 CmdAlarmSet（报警方式）与 CmdSettingSet
//  （最大大剂量、最大基础率、低药量报警阈值）。
//

import Foundation

struct PumpConfig: Codable, Equatable {

    /// 报警方式，见 EquilAlarmMode。AAPS 默认 TONE_AND_SHAKE，本 App 默认静音。
    var alarmModeRaw: Int = EquilAlarmMode.mute.rawValue
    /// 泵允许的单次最大大剂量（U）。AAPS 的输入框范围 1–25，默认 10。
    /// 这是泵固件的硬限制；App 侧单次上限如果更大，闸门会按这个值拦。
    var maxBolus: Double = 10
    /// 泵允许的最大基础率（U/h）。AAPS 的输入框范围 0.5–15。
    var maxBasal: Double = 5.0
    /// 低药量报警阈值（U）。AAPS 写死 16.00 U，这里开放到 10–50，默认取区间下限 10。
    var lowReservoir: Double = 10
    /// 大剂量输注速率，存的是「秒/单位」（AAPS 的 EquilBolusSpeed 同样存秒）。
    /// 40 = 1.5 U/min，20 = 3，10 = 6，5 = 12。默认 20（3 U/min）。
    /// 注意：这个值**不下发到泵**，它只改变 App 发大剂量命令时填的 stepTime。
    var bolusSecondsPerUnit: Int = BolusSpeed.fast.rawValue

    var bolusSpeed: BolusSpeed {
        get { BolusSpeed.from(seconds: bolusSecondsPerUnit) }
        set { bolusSecondsPerUnit = newValue.rawValue }
    }

    var alarmMode: EquilAlarmMode {
        get { EquilAlarmMode.from(alarmModeRaw) }
        set { alarmModeRaw = newValue.rawValue }
    }

    static let maxBolusRange: ClosedRange<Double> = 1...25
    static let maxBasalRange: ClosedRange<Double> = 0.5...15
    static let lowReservoirRange: ClosedRange<Double> = 10...50

    /// 规范化到合法区间。读到脏数据（手改 UserDefaults、旧版本遗留）时兜底。
    func sanitized() -> PumpConfig {
        var c = self
        if EquilAlarmMode(rawValue: alarmModeRaw) == nil { c.alarmModeRaw = EquilAlarmMode.mute.rawValue }
        c.maxBolus = min(max(maxBolus, Self.maxBolusRange.lowerBound), Self.maxBolusRange.upperBound)
        c.maxBasal = min(max(maxBasal, Self.maxBasalRange.lowerBound), Self.maxBasalRange.upperBound)
        c.lowReservoir = min(max(lowReservoir, Self.lowReservoirRange.lowerBound), Self.lowReservoirRange.upperBound)
        // 速度只认四档。不在档位上的值吸附到最近档，避免把未验证的速度
        // （比如 2 U/min）当成合法值发给泵。
        c.bolusSecondsPerUnit = BolusSpeed.from(seconds: bolusSecondsPerUnit).rawValue
        return c
    }

    /// 写泵前的一致性检查。返回 nil 表示可以写，否则是拒绝原因。
    func conflict(withMaxSingleDose appLimit: Double) -> String? {
        if appLimit > maxBolus {
            return String(format: "App 侧单次上限 %.2f U 高于泵侧 %.0f U，泵会拒绝。先把「剂量安全 → 单次上限」调到不超过 %.0f U。",
                          appLimit, maxBolus, maxBolus)
        }
        return nil
    }
}

// MARK: - 向后兼容的解码
extension PumpConfig {

    enum CodingKeys: String, CodingKey {
        case alarmModeRaw, maxBolus, maxBasal, lowReservoir, bolusSecondsPerUnit
    }

    /// 手写解码的唯一理由：新增字段要能兼容旧版本存下来的 JSON。
    ///
    /// Swift 合成的 `init(from:)` 遇到缺失的 key 会直接抛 `keyNotFound`，
    /// 而 `loadPumpConfig()` 用的是 `try?` —— 解码一失败，用户的报警方式、
    /// 最大大剂量、基础率上限全部悄悄回默认值。加一个字段就把旧设置清空，
    /// 这种 bug 只会在别人手机上出现，自己测不出来。
    ///
    /// 用 decodeIfPresent + 属性默认值，以后再加字段同样安全。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        if let v = try c.decodeIfPresent(Int.self, forKey: .alarmModeRaw) { alarmModeRaw = v }
        if let v = try c.decodeIfPresent(Double.self, forKey: .maxBolus) { maxBolus = v }
        if let v = try c.decodeIfPresent(Double.self, forKey: .maxBasal) { maxBasal = v }
        if let v = try c.decodeIfPresent(Double.self, forKey: .lowReservoir) { lowReservoir = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .bolusSecondsPerUnit) { bolusSecondsPerUnit = v }
    }
}
