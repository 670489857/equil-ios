//
//  CmdInsulinChange.swift
//  EquilKit
//
//  Byte-azonos port: AndroidAPS pump/equil manager/command/CmdInsulinChange.kt
//  Mérvadó forrás: nightscout/AndroidAPS (AGPL-3.0)
//
//  换储药器 / 解绑前复位。port = 0404 (default).
//    getFirstData: index(4LE) ++ [0x01,0x06] ++ 32000(4LE)
//    getNextData : index(4LE) ++ [0x00,0x06,0x01] ++ 0(4LE)
//    decodeConfirmData → status = data[6] & 0xFF, cmdSuccess = true
//
//  AAPS 里这条命令出现在两个地方：
//    1. 换储药器（startChangeInsulin）—— 把推杆退回去，好装新药；
//    2. 解绑（startUnpairDetach）—— 解绑前先让推杆退回到底，再 STOP。
//  32000 就是 EQUIL_STEP_MAX：一次给满行程，泵自己走到限位。
//

import Foundation

final class CmdInsulinChange: EquilBaseSetting {

    /// 泵回包里的状态字节（data[6]）。0 表示正常，其它值照原样记录到日志。
    private(set) var status: Int = 0

    /// AAPS 里 CmdInsulinChange 固定发 EQUIL_STEP_MAX = 32000。
    private let step = 32000

    override init(createTime: Int64, equilDevice: String, equilPassword: String) {
        super.init(createTime: createTime, equilDevice: equilDevice, equilPassword: equilPassword)
        // port marad "0404" (BaseCmd default)
    }

    override var commandLabel: String { "储药器复位 / 推杆退回 (CmdInsulinChange)" }

    override func getFirstData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x01, 0x06]
        let data3 = EquilUtils.intToBytes(step)
        let data = EquilUtils.concat(indexByte, data2, data3)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func getNextData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x00, 0x06, 0x01]
        let data3 = EquilUtils.intToBytes(0)
        let data = EquilUtils.concat(indexByte, data2, data3)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func decodeConfirmData(_ data: [UInt8]) {
        if data.count > 6 {
            status = Int(data[6])
        }
        EquilBaseCmd.dlog("🔬 CmdInsulinChange: 推杆退回完成, status=\(status)")
        cmdSuccess = true
    }
}
