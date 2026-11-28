//
//  CmdBasalGet.swift
//  EquilController
//
//  逐字节对齐 AAPS 4.0 pump/equil/manager/command/CmdBasalGet.kt（AGPL-3.0）。
//
//  读取泵当前运行的基础率（对应 AAPS #2454）。泵返回 24 小时 × 2 个半小时 = 48 个值，
//  每个值是那半小时的胰岛素量，步长 0.00625 U，两字节低字节在前。
//  每小时速率 = (第 2h 个半小时 + 第 2h+1 个半小时) × 0.00625。
//
//  port 用基类默认的 0404（AAPS 没有改 port）。
//  超时 8 秒：AAPS 注释说读命令在已建立的连接上约 1 秒返回，
//  不设 8 秒的话设置基础率方案要白等 22 秒。
//

import Foundation

final class CmdBasalGet: EquilBaseSetting {

    /// 从 0 点起每小时的基础率（U/h）。泵没答复前为 nil。
    private(set) var hourlyRates: [Double]?

    private static let ratesStart = 6
    private static let halfHours = 48
    private static let step = 0.00625

    override init(createTime: Int64, equilDevice: String, equilPassword: String) {
        super.init(createTime: createTime, equilDevice: equilDevice, equilPassword: equilPassword)
        // port 保持 0404
    }

    override var commandLabel: String { "读取基础率（CmdBasalGet）" }

    override func getFirstData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x02, 0x02]
        let data = EquilUtils.concat(indexByte, data2)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func getNextData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data2: [UInt8] = [0x00, 0x02, 0x01]
        let data = EquilUtils.concat(indexByte, data2)
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    // 与 CmdInsulinGet 一致：从 Msg2 的响应解密，不再发第三条消息。
    override func decodeConfirm() throws -> EquilResponse {
        let model = decodeModel()
        runCode = model.code
        guard let runPwd else { throw EquilError.invalidState("runPwd nil") }
        let content = try AESUtil.decrypt(model, key: EquilUtils.hexStringToBytes(runPwd))
        decodeConfirmData(EquilUtils.hexStringToBytes(content))
        return EquilResponse(createTime: createTime)
    }

    override func decodeConfirmData(_ data: [UInt8]) {
        EquilBaseCmd.dlog("🔬 CmdBasalGet confirm content=\(EquilUtils.bytesToHex(data)) (\(data.count)B)")

        // 长度不够 48 个半小时：这是 ack 而不是答案。既不算失败，也不覆盖之前读到的表。
        let needed = Self.ratesStart + 2 * Self.halfHours
        guard data.count >= needed else {
            EquilBaseCmd.dlog("🔬 CmdBasalGet: 数据长度 \(data.count) < \(needed)，按 ack 处理")
            return
        }

        var rates: [Double] = []
        rates.reserveCapacity(24)
        for hour in 0..<24 {
            let a = Self.halfHour(data, index: 2 * hour)
            let b = Self.halfHour(data, index: 2 * hour + 1)
            rates.append(Double(a + b) * Self.step)
        }
        hourlyRates = rates
        cmdSuccess = true
        EquilBaseCmd.dlog("🔬 CmdBasalGet 每小时基础率: \(rates.map { String(format: "%.4f", $0) }.joined(separator: ", "))")
    }

    /// 第 index 个半小时的值。低字节在前：data[off] 低、data[off+1] 高。
    private static func halfHour(_ data: [UInt8], index: Int) -> Int {
        let off = ratesStart + 2 * index
        guard off + 1 < data.count else { return 0 }
        return EquilUtils.bytesToInt(data[off + 1], data[off])
    }
}
