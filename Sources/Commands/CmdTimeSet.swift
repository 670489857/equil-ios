//
//  CmdTimeSet.swift
//  EquilController
//
//  逐字节对齐 AAPS 4.0 pump/equil/manager/command/CmdTimeSet.kt（AGPL-3.0）。
//
//  把手机当前时间写进泵。port = 0505。
//    getFirstData: index(4LE) ++ [0x01,0x00] ++ [年-2000, 月, 日, 时, 分, 秒]（各 1 字节）
//    getNextData : index(4LE) ++ [0x00,0x00,0x01]
//
//  泵的时钟漂移会让历史记录和剂量时间线错位，AAPS 在每次连接后都会校时。
//  这里不自动执行——时间写错比不写更糟，交给用户显式点。
//

import Foundation

final class CmdTimeSet: EquilBaseSetting {

    override init(createTime: Int64, equilDevice: String, equilPassword: String) {
        super.init(createTime: createTime, equilDevice: equilDevice, equilPassword: equilPassword)
        port = "0505"
    }

    override var commandLabel: String { "校时（CmdTimeSet）" }

    override func getFirstData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x01, 0x00]

        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let year = UInt8(truncatingIfNeeded: (comps.year ?? 2000) - 2000)
        let month = UInt8(truncatingIfNeeded: comps.month ?? 1)
        let day = UInt8(truncatingIfNeeded: comps.day ?? 1)
        let hour = UInt8(truncatingIfNeeded: comps.hour ?? 0)
        let minute = UInt8(truncatingIfNeeded: comps.minute ?? 0)
        let second = UInt8(truncatingIfNeeded: comps.second ?? 0)

        let data3: [UInt8] = [year, month, day, hour, minute, second]
        let data = EquilUtils.concat(indexByte, data2, data3)
        EquilBaseCmd.pumpReqIndex += 1
        EquilBaseCmd.dlog("🔬 CmdTimeSet: \(Int(year) + 2000)-\(month)-\(day) \(hour):\(minute):\(second)")
        return data
    }

    override func getNextData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x00, 0x00, 0x01]
        let data = EquilUtils.concat(indexByte, data2)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func decodeConfirmData(_ data: [UInt8]) {
        EquilBaseCmd.dlog("🔬 CmdTimeSet: 泵已接受校时")
        cmdSuccess = true
    }
}
