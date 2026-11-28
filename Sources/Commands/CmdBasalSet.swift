//
//  CmdBasalSet.swift
//  EquilController
//
//  逐字节对齐 AAPS 4.0 pump/equil/manager/command/CmdBasalSet.kt（AGPL-3.0）。
//
//  写入 24 小时基础率方案。端口沿用基类默认 0404，走 BaseSetting 三步握手。
//    getFirstData:  index(4LE) ++ [01,02]
//                   ++ 每小时 4 字节：halfLow, halfHigh, halfLow, halfHigh
//       其中 half = rate/2（半小时量），step = floor(half / 0.00625)，低字节在前。
//    getNextData:   index(4LE) ++ [00,02,01]
//    decodeConfirmData: cmdSuccess = true（与 AAPS 一致，只认握手完成）
//
//  泵实际给到的速率是 0.0125 U/h 的整数倍（每半小时 0.00625 取整后乘 2），
//  所以 1.0 U/h 这种值会被截成 0.9875 U/h —— deliveredRate 复刻了同样的截断。
//

import Foundation

final class CmdBasalSet: EquilBaseSetting {

    /// 0 点起 24 个整点的基础率（U/h）。
    let hourlyRates: [Double]

    init(hourlyRates: [Double],
         equilDevice: String,
         equilPassword: String,
         createTime: Int64) {
        self.hourlyRates = Array(hourlyRates.prefix(24))
        super.init(createTime: createTime, equilDevice: equilDevice, equilPassword: equilPassword)
    }

    override var commandLabel: String { "写入基础率（CmdBasalSet）" }

    override func getFirstData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        var data = EquilUtils.concat(indexByte, [0x01, 0x02])
        for hour in 0..<24 {
            let rate = hour < hourlyRates.count ? hourlyRates[hour] : 0
            let step = Self.stepForHalfHour(rate / 2)
            let lo = UInt8(step & 0xFF)
            let hi = UInt8((step >> 8) & 0xFF)
            data = EquilUtils.concat(data, [lo, hi, lo, hi])
        }
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func getNextData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data = EquilUtils.concat(indexByte, [0x00, 0x02, 0x01])
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func decodeConfirmData(_ data: [UInt8]) {
        EquilBaseCmd.dlog("🔬 CmdBasalSet confirm \(EquilUtils.bytesToHex(data)) (\(data.count)B)")
        cmdSuccess = true
    }

    /// 半小时剂量 → 0.00625 U 步进（向下取整，与 AAPS decodeSpeedToUH(Double) 一致）。
    static func stepForHalfHour(_ halfRate: Double) -> Int {
        guard halfRate > 0 else { return 0 }
        // 0.00625 = 1/160，用整数化避免二进制浮点截断误差
        return Int((halfRate * 160 + 1e-9).rounded(.down))
    }

    /// 泵真正会执行的速率（每半小时取整后 ×2 × 0.00625）。
    static func deliveredRate(_ rate: Double) -> Double {
        Double(stepForHalfHour(rate / 2)) * 2 * 0.00625
    }

    /// 方案摘要，写入成功后回显给界面核对。
    var summary: String {
        let delivered = (0..<24).map { Self.deliveredRate(hourlyRates[$0]) }
        return "0 时起 \(delivered.prefix(6).map { String(format: "%.4f", $0) }.joined(separator: " / ")) … U/h"
    }
}
