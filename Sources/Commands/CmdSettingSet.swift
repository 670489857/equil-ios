//
//  CmdSettingSet.swift
//  EquilKit
//
//  Byte-azonos port: AndroidAPS pump/equil manager/command/CmdSettingSet.kt
//  Mérvadó forrás: nightscout/AndroidAPS (AGPL-3.0)
//
//  PÁROSÍTÁS 4. (utolsó) LÉPÉSE — küszöbök beállítása. BaseSetting kézfogás,
//  DEFAULT_PORT (0F0F). isPairStep = true.
//
//   - getFirstData:  index(4LE) ++ [01,05]
//        ++ intToBytes(0)        [useTime]      (4 byte LE)
//        ++ intToBytes(0)        [autoCloseTime](4 byte LE)
//        ++ intToTwoBytes(1600)  [lowAlarm]     (2 byte)
//        ++ intToTwoBytes(0)     [fastBolus]    (2 byte)
//        ++ intToTwoBytes(2800)  [occlusion]    (2 byte)
//        ++ intToTwoBytes(8)     [insulinUnit]  (2 byte)
//        ++ intToTwoBytes(basalThresholdStep)   (2 byte)
//        ++ intToTwoBytes(bolusThresholdStep)   (2 byte)
//        pumpReqIndex++
//   - getNextData:   index(4LE) ++ [00,05,01]   pumpReqIndex++
//   - decodeConfirmData:  cmdSuccess = true.
//
//   basalThresholdStep = decodeSpeedToUH(maxBasal)
//   bolusThresholdStep = decodeSpeedToUH(maxBolus)
//

import Foundation

final class CmdSettingSet: EquilBaseSetting {

    let bolusThresholdStep: Int
    let basalThresholdStep: Int
    /// 低药量报警阈值（U）。AAPS 这里写死 1600（=16.00 U），
    /// 协议上是 ×100 的定点数。默认给 16 保持与 AAPS 一致。
    let lowAlarm: Double

    init(maxBolus: Double,
         maxBasal: Double,
         lowAlarm: Double = 16.0,
         equilDevice: String,
         equilPassword: String,
         createTime: Int64) {
        self.bolusThresholdStep = EquilUtils.decodeSpeedToUH(maxBolus)
        self.basalThresholdStep = EquilUtils.decodeSpeedToUH(maxBasal)
        self.lowAlarm = lowAlarm
        super.init(createTime: createTime, equilDevice: equilDevice, equilPassword: equilPassword)
        // BaseSetting DEFAULT_PORT (0F0F) — a CmdSettingSet nem írja felül a portot.
    }

    override var commandLabel: String { "Beállítások (CmdSettingSet)" }

    override func getFirstData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let equilCmd: [UInt8] = [0x01, 0x05]
        let useTime = EquilUtils.intToBytes(0)
        let autoCloseTime = EquilUtils.intToBytes(0)
        let lowAlarmByte = EquilUtils.intToTwoBytes(Self.encodeLowAlarm(lowAlarm))
        let fastBolus = EquilUtils.intToTwoBytes(0)
        let occlusion = EquilUtils.intToTwoBytes(2800)
        let insulinUnit = EquilUtils.intToTwoBytes(8)
        let basalThreshold = EquilUtils.intToTwoBytes(basalThresholdStep)
        let bolusThreshold = EquilUtils.intToTwoBytes(bolusThresholdStep)
        var data = EquilUtils.concat(indexByte, equilCmd)
        data = EquilUtils.concat(data, useTime)
        data = EquilUtils.concat(data, autoCloseTime)
        data = EquilUtils.concat(data, lowAlarmByte)
        data = EquilUtils.concat(data, fastBolus)
        data = EquilUtils.concat(data, occlusion)
        data = EquilUtils.concat(data, insulinUnit)
        data = EquilUtils.concat(data, basalThreshold)
        data = EquilUtils.concat(data, bolusThreshold)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func getNextData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x00, 0x05, 0x01]
        let data = EquilUtils.concat(indexByte, data2)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func decodeConfirmData(_ data: [UInt8]) {
        cmdSuccess = true
    }

    /// 低药量阈值按 ×100 的定点数下发（AAPS 写死 1600 = 16.00 U）。
    /// 夹在 10–50 U 之间：低于 10 U 泵会提前报警，高于 50 U 等于关掉了保护。
    static func encodeLowAlarm(_ units: Double) -> Int {
        let clamped = min(max(units, 10), 50)
        return Int((clamped * 100).rounded())
    }
}
