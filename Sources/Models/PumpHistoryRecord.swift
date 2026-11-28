//
//  PumpHistoryRecord.swift
//  EquilController
//
//  泵内历史库的一条记录。
//
//  与「本机审计日志」的区别：
//  - 本机审计日志（AuditLog）只记这台手机下发过什么，换台手机就没了；
//  - 泵内历史库是泵自己在每次事件后写的一条记录，换手机也还在，AAPS 的
//    「历史」页读的就是它（CmdHistoryGet，端口 0x0505，按绝对序号寻址）。
//
//  字段定义与 AAPS `EquilManager.decodeHistory` 一致：
//    time = data[6..11]（年-2000 / 月 / 日 / 时 / 分 / 秒）
//    battery = data[12]、insulin = data[13]（整数 U）、rate = data[14..15]（1/160 U/h）
//    largeRate = data[16..17]（大剂量速度，1/160 U/min）
//    index = data[18..19]、port = data[20]、type = data[21]、level = data[22]、parm = data[23]
//

import SwiftUI

/// 事件等级，只影响颜色，不参与任何控制逻辑。
enum PumpEventSeverity {
    case info
    case warning
    case critical

    var tint: Color {
        switch self {
        case .info:     return .primary
        case .warning:  return .orange
        case .critical: return .red
        }
    }
}

/// 泵内事件的语义。(port, type, level) 三元组与 AAPS `PumpEvent.eventResMap` 一一对应。
enum PumpEventKind: Equatable {
    case reservoirLow          // (4,1,1)
    case reservoirEmpty        // (4,1,2)
    case blockage              // (4,2,2)
    case motorReversal         // (4,3,0)
    case motorFault            // (4,3,2)
    case pauseRequested        // (4,5,0)
    case alreadyPaused         // (4,5,1)
    case shutdownSoon          // (4,6,1)
    case autoOff               // (4,6,2)
    case prime                 // (4,7,0)
    case rewind                // (4,8,0)
    case bolusStarted          // (4,9,0)
    case tempBasalStarted      // (4,10,0)
    case tempBasalEnded        // (4,11,0)
    case batteryLow            // (5,0,1)
    case batteryEmpty          // (5,0,2)
    case powerOnReset          // (5,1,0)
    case infusionStopped       // (5,1,2)
    case unknown

    init(port: Int, type: Int, level: Int) {
        switch (port, type, level) {
        case (4, 1, 1): self = .reservoirLow
        case (4, 1, 2): self = .reservoirEmpty
        case (4, 2, 2): self = .blockage
        case (4, 3, 0): self = .motorReversal
        case (4, 3, 2): self = .motorFault
        case (4, 5, 0): self = .pauseRequested
        case (4, 5, 1): self = .alreadyPaused
        case (4, 6, 1): self = .shutdownSoon
        case (4, 6, 2): self = .autoOff
        case (4, 7, 0): self = .prime
        case (4, 8, 0): self = .rewind
        case (4, 9, 0): self = .bolusStarted
        case (4, 10, 0): self = .tempBasalStarted
        case (4, 11, 0): self = .tempBasalEnded
        case (5, 0, 1): self = .batteryLow
        case (5, 0, 2): self = .batteryEmpty
        case (5, 1, 0): self = .powerOnReset
        case (5, 1, 2): self = .infusionStopped
        default:        self = .unknown
        }
    }

    var label: String {
        switch self {
        case .reservoirLow:     return "储药器余量偏低"
        case .reservoirEmpty:   return "储药器已空"
        case .blockage:         return "检测到输注堵塞"
        case .motorReversal:    return "检测到电机反转"
        case .motorFault:       return "检测到电机故障"
        case .pauseRequested:   return "开始暂停输注"
        case .alreadyPaused:    return "输注已处于暂停"
        case .shutdownSoon:     return "即将自动关机"
        case .autoOff:          return "已自动关机"
        case .prime:            return "储药器排气"
        case .rewind:           return "推杆退回（换储药器）"
        case .bolusStarted:     return "大剂量开始"
        case .tempBasalStarted: return "临时基础率开始"
        case .tempBasalEnded:   return "临时基础率结束"
        case .batteryLow:       return "电量偏低"
        case .batteryEmpty:     return "电池耗尽"
        case .powerOnReset:     return "上电复位"
        case .infusionStopped:  return "输注异常已停止"
        case .unknown:          return "其它泵记录"
        }
    }

    var severity: PumpEventSeverity {
        switch self {
        case .reservoirLow, .pauseRequested, .alreadyPaused, .batteryLow, .shutdownSoon:
            return .warning
        case .reservoirEmpty, .blockage, .motorReversal, .motorFault,
             .autoOff, .batteryEmpty, .infusionStopped:
            return .critical
        default:
            return .info
        }
    }
}

/// 一条泵端历史记录。
struct PumpHistoryRecord: Identifiable, Equatable {
    let index: Int
    let time: Date
    let battery: Int
    let insulin: Int
    /// 基础率，U/h。
    let rate: Double
    let port: Int
    let type: Int
    let level: Int
    let parm: Int

    var id: Int { index }

    var event: PumpEventKind { PumpEventKind(port: port, type: type, level: level) }
    var label: String { event.label }
    var severity: PumpEventSeverity { event.severity }
    /// AAPS `PumpEvent.eventResMap` 里没有这一组三元组 —— 泵写了记录，但语义未公开。
    var isUnmapped: Bool { event == .unknown }

    /// 副行文字：序号 + 那一刻的泵状态。没有的字段不写，避免一串「0」。
    var detail: String {
        var parts = ["#\(index)"]
        if battery >= 0 { parts.append("电池 \(battery)%") }
        if insulin >= 0 { parts.append("余量 \(insulin) U") }
        if rate > 0 { parts.append(String(format: "速率 %.2f U/h", rate)) }
        // 未映射的记录把原始三元组连同参数一起留着，否则没有任何线索可查。
        if isUnmapped {
            parts.append("port \(port) / type \(type) / level \(level) / parm \(parm)")
        }
        return parts.joined(separator: " · ")
    }
}
