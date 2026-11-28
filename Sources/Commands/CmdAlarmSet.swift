//
//  CmdAlarmSet.swift
//  EquilKit
//
//  Byte-azonos port: AndroidAPS pump/equil manager/command/CmdAlarmSet.kt
//  Mérvadó forrás: nightscout/AndroidAPS (AGPL-3.0)
//
//  报警方式的设置。走 BaseSetting 的三段握手，端口沿用 BaseCmd 默认的 0404
//  （与 AAPS 一致：CmdAlarmSet 没有覆盖 port）。
//
//    getFirstData: index(4LE) ++ [0x01, 0x0b] ++ mode(4LE)
//    getNextData : index(4LE) ++ [0x00, 0x0b, 0x01]
//    decodeConfirmData → cmdSuccess = true
//
//  mode 取值见 AlarmMode：0 静音 / 1 声音 / 2 震动 / 3 声音和震动。
//

import Foundation

/// 泵的报警方式。对应 AAPS `app.aaps.pump.equil.data.AlarmMode`。
enum EquilAlarmMode: Int, CaseIterable, Identifiable {
    case mute = 0
    case tone = 1
    case shake = 2
    case toneAndShake = 3

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .mute:         return "静音"
        case .tone:         return "声音"
        case .shake:        return "震动"
        case .toneAndShake: return "声音和震动"
        }
    }

    /// 越界时回落到 AAPS 的默认值 TONE_AND_SHAKE。
    static func from(_ raw: Int) -> EquilAlarmMode {
        EquilAlarmMode(rawValue: raw) ?? .toneAndShake
    }
}

final class CmdAlarmSet: EquilBaseSetting {

    let mode: Int

    init(mode: Int, createTime: Int64, equilDevice: String, equilPassword: String) {
        self.mode = mode
        super.init(createTime: createTime, equilDevice: equilDevice, equilPassword: equilPassword)
        // port marad "0404" (BaseCmd default) — az AAPS is így használja
    }

    override var commandLabel: String { "Beállítások (CmdAlarmSet mode=\(mode))" }

    override func getFirstData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x01, 0x0B]
        let data3 = EquilUtils.intToBytes(mode)
        let data = EquilUtils.concat(indexByte, data2, data3)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func getNextData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x00, 0x0B, 0x01]
        let data = EquilUtils.concat(indexByte, data2)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func decodeConfirmData(_ data: [UInt8]) {
        EquilBaseCmd.dlog("🔬 CmdAlarmSet: 报警方式 = \(mode)")
        cmdSuccess = true
    }
}
