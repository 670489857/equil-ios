//
//  CmdLargeBasalSet.swift
//  EquilKit
//
//  Byte-azonos port: AndroidAPS pump/equil manager/command/CmdLargeBasalSet.kt
//  Mérvadó forrás: nightscout/AndroidAPS (AGPL-3.0)
//
//  BÓLUS parancs. port = 0404 (örökölt default, nincs felülírva).
//    step     = (insulin / 0.05 * 8).toInt()          // 160 step / U
//    stepTime = (insulin * secondsPerUnit).roundToInt().coerceAtLeast(1)
//  AAPS 4.0 起速度由 stepTime 决定：
//    secondsPerUnit 40 = 1.5 U/min (standard) / 20 = 3 / 10 = 6 / 5 = 12 U/min
//  4.0 之前是写死的 (insulin / 0.05 * 2)，等价于 40 秒/U。
//
//  getFirstData (22 byte):
//    index(4LE) ++ [0x01,0x03] ++ step(4LE) ++ stepTime(4LE) ++ 0(4LE) ++ 0(4LE)
//  getNextData (11 byte):
//    index(4LE) ++ [0x00,0x03,0x01] ++ 0(4LE)
//
//  Példa (insulin=0.05, pumpReqIndex=10):
//    0A000000 0103 08000000 02000000 00000000 00000000
//

import Foundation

final class CmdLargeBasalSet: EquilBaseSetting {

    let insulin: Double
    /// 每单位用多少秒推完 —— 协议里没有「速度」字段，速度就是靠它表达的。
    /// 40 = 1.5 U/min（标准），20 = 3，10 = 6，5 = 12。
    let secondsPerUnit: Int
    var step: Int = 0
    var stepTime: Int = 0

    init(insulin: Double,
         secondsPerUnit: Int = EquilConst.EQUIL_BOLUS_SECONDS_PER_UNIT_STANDARD,
         createTime: Int64,
         equilDevice: String,
         equilPassword: String) {
        self.insulin = insulin
        self.secondsPerUnit = secondsPerUnit
        super.init(createTime: createTime, equilDevice: equilDevice, equilPassword: equilPassword)
        // port marad "0404" (BaseCmd default)
        if insulin != 0.0 {
            // AAPS 原版是 (insulin / 0.05 * 8).toInt()，Int() 对负数截断、
            // 对浮点误差也截断：0.075 / 0.05 * 8 在 Double 里等于
            // 11.999999999999998，toInt() 得到 11，少发 0.00625 U。
            // 改成四舍五入，落在最近的 step 上。
            step = Int((insulin / 0.05 * 8).rounded())
            // AAPS 4.0：stepTime = (insulin * secondsPerUnit).roundToInt().coerceAtLeast(1)
            // 至少 1 秒 —— 高速档下 0.05 U 只要 0.25 秒，四舍五入会变成 0，
            // 泵收到 0 秒的输注指令行为未定义，直接给 1 秒更安全（实际会慢一点点）。
            stepTime = max(1, Int((insulin * Double(secondsPerUnit)).rounded()))
        }
    }

    override var commandLabel: String { "Bólusz (CmdLargeBasalSet)" }

    override func getFirstData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x01, 0x03]
        let data3 = EquilUtils.intToBytes(step)
        let data4 = EquilUtils.intToBytes(stepTime)
        let data5 = EquilUtils.intToBytes(0)
        let data = EquilUtils.concat(indexByte, data2, data3, data4, data5, data5)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func getNextData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x00, 0x03, 0x01]
        let data3 = EquilUtils.intToBytes(0)
        let data = EquilUtils.concat(indexByte, data2, data3)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func decodeConfirmData(_ data: [UInt8]) {
        cmdSuccess = true
    }
}
