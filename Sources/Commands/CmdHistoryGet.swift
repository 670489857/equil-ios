//
//  CmdHistoryGet.swift
//  EquilKit
//
//  Byte-azonos port: AndroidAPS pump/equil manager/command/CmdHistoryGet.kt
//  Mérvadó forrás: nightscout/AndroidAPS (AGPL-3.0)
//
//  PUMPA-ÁLLAPOT / ELŐZMÉNYEK lekérdezése. port = 0505.
//    currentIndex = 0 → a pumpa aktuális (legfrissebb) állapotát kéri.
//    getFirstData: index(4LE) ++ [0x02,0x01] ++ currentIndex(4LE)
//    getNextData : index(4LE) ++ [0x00,0x01,0x01]
//    decodeConfirmData (data[6..]):
//      year=d6 month=d7 day=d8 hour=d9 min=d10 sec=d11
//      battery=d12  medicine=d13  rate=bytesToInt(d15,d14)
//      index=bytesToInt(d19,d18)  type=d21  level=d22  parm=d23
//    decodeConfirm() → status olvasás, NINCS 3. üzenet.
//

import Foundation

final class CmdHistoryGet: EquilBaseSetting {

    let currentIndex: Int

    var battery: Int = -1
    var medicine: Int = -1   // tartály / inzulin állapot jelző
    var rate: Int = 0
    var recordIndex: Int = 0
    var type: Int = 0
    var level: Int = 0
    var parm: Int = 0
    var ts: String = ""
    /// 事件端口的第三段（AAPS: data[20]）。history 事件的语义由 (port, type, level) 共同决定。
    var portCode: Int = 0
    /// 大剂量速度，原始 16 位（1/160 U/min）。AAPS 用整 16 位，不用 bytesToInt。
    var largeRate: Int = 0
    /// 记录发生时刻（泵本地时间的年月日时分秒）。
    var eventDate: Date?

    init(currentIndex: Int, createTime: Int64, equilDevice: String, equilPassword: String) {
        self.currentIndex = currentIndex
        super.init(createTime: createTime, equilDevice: equilDevice, equilPassword: equilPassword)
        port = "0505"
    }

    override var commandLabel: String { "Előzmények/állapot (CmdHistoryGet)" }

    override func getFirstData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x02, 0x01]
        let data3 = EquilUtils.intToBytes(currentIndex)
        let data = EquilUtils.concat(indexByte, data2, data3)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func getNextData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x00, 0x01, 0x01]
        let data = EquilUtils.concat(indexByte, data2)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    // AAPS: a Msg2 válaszából dekódol, NEM küld 3. üzenetet.
    override func decodeConfirm() throws -> EquilResponse {
        let model = decodeModel()
        runCode = model.code
        guard let runPwd = runPwd else { throw EquilError.invalidState("runPwd nil") }
        let content = try AESUtil.decrypt(model, key: EquilUtils.hexStringToBytes(runPwd))
        decodeConfirmData(EquilUtils.hexStringToBytes(content))
        return EquilResponse(createTime: createTime)
    }

    override func decodeConfirmData(_ data: [UInt8]) {
        EquilBaseCmd.dlog("🔬 CmdHistoryGet confirm content=\(EquilUtils.bytesToHex(data)) (\(data.count)B)")
        guard data.count >= 24 else {
            EquilBaseCmd.dlog("🔬 CmdHistoryGet: content túl rövid (\(data.count)B)")
            cmdSuccess = true
            return
        }
        let year = Int(data[6]) & 0xff
        let month = Int(data[7]) & 0xff
        let day = Int(data[8]) & 0xff
        let hour = Int(data[9]) & 0xff
        let min = Int(data[10]) & 0xff
        let sec = Int(data[11]) & 0xff
        ts = String(format: "20%02d-%02d-%02d %02d:%02d:%02d", year, month, day, hour, min, sec)
        battery = Int(data[12]) & 0xff
        medicine = Int(data[13]) & 0xff
        rate = EquilUtils.bytesToInt(data[15], data[14])
        recordIndex = EquilUtils.bytesToInt(data[19], data[18])
        portCode = Int(data[20]) & 0xff
        type = Int(data[21]) & 0xff
        level = Int(data[22]) & 0xff
        parm = Int(data[23]) & 0xff
        // 大剂量速度取整 16 位：bytesToInt 会丢掉最高位，6 U/min（57600）就需要它。
        largeRate = (Int(data[17]) & 0xff) << 8 | (Int(data[16]) & 0xff)
        // 泵给的是「年-2000」，月/日/时/分/秒都是 1 基的本地时间。
        // DateComponents 的字段是 Int?，先取成本地常量再比较，避免逐字段解包。
        let y = 2000 + (Int(data[6]) & 0xff)
        let mo = Int(data[7]) & 0xff
        let d = Int(data[8]) & 0xff
        let h = Int(data[9]) & 0xff
        let mi = Int(data[10]) & 0xff
        let se = Int(data[11]) & 0xff
        if mo >= 1, mo <= 12, d >= 1, d <= 31, h < 24, mi < 60, se < 60 {
            var comps = DateComponents()
            comps.year = y
            comps.month = mo
            comps.day = d
            comps.hour = h
            comps.minute = mi
            comps.second = se
            eventDate = Calendar.current.date(from: comps)
        }
        EquilBaseCmd.dlog("🔬 CmdHistoryGet: idő=\(ts) akku=\(battery)% tartály=\(medicine) ráta=\(rate) idx=\(recordIndex) type=\(type) level=\(level) parm=\(parm)")
        cmdSuccess = true
    }
}
