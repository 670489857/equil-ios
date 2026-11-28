//
//  BolusSpeed.swift
//  EquilController
//
//  大剂量输注速率。
//
//  Equil 的协议里没有「速度」这个字段 —— 大剂量命令 (CmdLargeBasalSet) 只带
//  两个数：剂量 (step，1/160 U) 和**持续时间 (stepTime，秒)**。泵按
//  「这么多量，用这么多秒推完」执行，所以速度完全由 stepTime 决定。
//
//  AAPS 4.0 的存法也一样：偏好里存的是「秒/单位」而不是 U/min
//  （EquilIntPreferenceKey.EquilBolusSpeed，默认 40，范围 5...40）。
//
//  这里只留两档：1.5 U/min（40 秒/U）和 3 U/min（20 秒/U）。
//  AAPS 源码注释里记着实测：12 U/min 还行，30 U/min 会触发
//  "Abnormal infusion stopped"（issue #5142）；6 / 12 两档用不上，去掉减少误选。
//

import Foundation

enum BolusSpeed: Int, CaseIterable, Identifiable {
    /// 1.5 U/min —— AAPS 出厂默认。
    case standard = 40
    /// 3 U/min —— 本 App 默认档。
    case fast = 20

    var id: Int { rawValue }

    /// 协议里真正下发的数：每单位用多少秒。
    var secondsPerUnit: Int { rawValue }

    var unitsPerMinute: Double { 60.0 / Double(rawValue) }

    var label: String {
        switch self {
        case .standard: return "1.5 U/min"
        case .fast:     return "3 U/min"
        }
    }

    /// 菜单里跟在档位后面的小字，两档格式一致：只有「秒/U」。
    var detail: String {
        switch self {
        case .standard: return "40 秒/U"
        case .fast:     return "20 秒/U"
        }
    }

    /// 从存储值还原。非法值（旧版本的 6 / 12 U/min、手改 UserDefaults）
    /// 吸附到最近的现存档位，不直接回退默认值 —— 6 U/min 更接近 3 U/min，
    /// 吸附到 3 比跳到 1.5 更符合原意。
    static func from(seconds: Int) -> BolusSpeed {
        if let exact = BolusSpeed(rawValue: seconds) { return exact }
        let clamped = min(max(seconds, 20), 40)
        return allCases.min {
            abs($0.rawValue - clamped) < abs($1.rawValue - clamped)
        } ?? .fast
    }
}
