//
//  CmdExtendedBolusSet.swift
//  EquilKit
//
//  Byte-azonos port: AndroidAPS pump/equil manager/command/CmdExtendedBolusSet.kt
//  Mérvadó forrás: nightscout/AndroidAPS (AGPL-3.0)
//
//  方波（延长波）大剂量。port = 0404（继承默认，未覆盖）。
//    step     = (insulin / 0.05 * 8).toInt()   // 160 step / U，与大剂量同一换算
//    pumpTime = durationInMinutes * 60         // 秒
//
//  getFirstData（22 byte）—— 注意字段顺序与大剂量不同：
//    index(4LE) ++ [0x01,0x03] ++ 0(4LE) ++ 0(4LE) ++ step(4LE) ++ pumpTime(4LE)
//  大剂量是 step 在前、stepTime 在后；方波是两个 0 在前、step 再 pumpTime。
//
//  getNextData（11 byte）与大剂量一致：
//    index(4LE) ++ [0x00,0x03,0x01] ++ 0(4LE)
//
//  取消：AAPS 用同一条命令，insulin = 0、duration = 0、cancel = true
//  （init 里 insulin == 0 时 step / pumpTime 保持 0）。
//

import Foundation

final class CmdExtendedBolusSet: EquilBaseSetting {

    let insulin: Double
    let durationMinutes: Int
    let cancel: Bool
    var step: Int = 0
    var pumpTime: Int = 0

    init(insulin: Double,
         durationMinutes: Int,
         cancel: Bool = false,
         createTime: Int64,
         equilDevice: String,
         equilPassword: String) {
        self.insulin = insulin
        self.durationMinutes = durationMinutes
        self.cancel = cancel
        super.init(createTime: createTime, equilDevice: equilDevice, equilPassword: equilPassword)
        // port marad "0404"
        if insulin != 0.0 {
            // 与大剂量同样的取整：AAPS 用 toInt() 截断，0.075 会掉成 11 step；
            // 这里四舍五入，落在最近的 step 上。
            step = Int((insulin / 0.05 * 8).rounded())
            pumpTime = durationMinutes * 60
        }
    }

    override var commandLabel: String {
        cancel ? "取消方波 (CmdExtendedBolusSet cancel)"
               : "方波 \(insulin) U / \(durationMinutes) min (CmdExtendedBolusSet)"
    }

    override func getFirstData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x01, 0x03]
        let zero = EquilUtils.intToBytes(0)
        let data3 = EquilUtils.intToBytes(step)
        let data4 = EquilUtils.intToBytes(pumpTime)
        let data = EquilUtils.concat(indexByte, data2, zero, zero, data3, data4)
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
        EquilBaseCmd.dlog("🔬 CmdExtendedBolusSet: OK, insulin=\(insulin) pumpTime=\(pumpTime)s cancel=\(cancel)")
        cmdSuccess = true
    }
}
