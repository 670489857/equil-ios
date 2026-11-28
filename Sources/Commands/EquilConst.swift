//
//  EquilConst.swift
//  EquilKit
//
//  Byte-azonos port: AndroidAPS pump/equil EquilConst.kt
//  Mérvadó forrás: nightscout/AndroidAPS (AGPL-3.0)
//
//  Equil pumpa konstansok. Az értékek pontosan az AAPS forrásból.
//

import Foundation

enum EquilConst {
    /// Parancs timeout (ms).
    static let EQUIL_CMD_TIME_OUT: Int64 = 300_000
    /// BLE írások közti minimális szünet (ms).
    static let EQUIL_BLE_WRITE_TIME_OUT: Int64 = 20
    /// Két parancs közti várakozás a párosítási flow-ban (ms).
    static let EQUIL_BLE_NEXT_CMD: Int64 = 500
    /// 标准大剂量速度：40 秒/U = 1.5 U/min。
    /// 泵按「持续时间」执行，改速度就是把这个值乘上剂量当 stepTime 发出去。
    static let EQUIL_BOLUS_SECONDS_PER_UNIT_STANDARD: Int = 40
    /// 支持范围内的最快档：5 秒/U = 12 U/min。实测 30 U/min 会让泵报「输注异常」。
    static let EQUIL_BOLUS_SECONDS_PER_UNIT_MIN: Int = 5
    /// Támogatott firmware-küszöb (1.0-gen pumpa: 5.3).
    static let EQUIL_SUPPORT_LEVEL: Float = 5.3
    /// Alapértelmezett bólus-küszöb lépés.
    static let EQUIL_BOLUS_THRESHOLD_STEP: Int = 1600
    /// Alapértelmezett basal-küszöb lépés.
    static let EQUIL_BASAL_THRESHOLD_STEP: Int = 240
    static let EQUIL_STEP_MAX: Int = 32_000
    static let EQUIL_STEP_FILL: Int = 160
    static let EQUIL_STEP_AIR: Int = 120
}
