//
//  CmdDevicesGet.swift
//  EquilKit
//
//  Byte-azonos port: AndroidAPS pump/equil manager/command/CmdDevicesGet.kt
//  Mérvadó forrás: nightscout/AndroidAPS (AGPL-3.0) — 4.0.0
//
//  设备信息查询（含固件版本）。port = "0000"，走 BaseSetting 标准三段式
//  （已配对状态用，第一帧就是普通 AES 握手，不是 CmdDevicesOldGet 的明文开场）。
//
//    getFirstData : index(4LE) ++ [0x02, 0x00]
//    getNextData  : index(4LE) ++ [0x00, 0x00, 0x01]
//    decodeConfirmData: fw = data[18] ++ "." ++ data[19]   （十进制，不是 hex）
//                       value = bytesToInt(data[7], data[6])
//
//  与 CmdDevicesOldGet 的区别：
//    - 前者在【配对前】用，泵还是陌生人，所以第一帧不加密、靠 0E0E 端口交换 key；
//    - 本命令在【已配对】后用，可以直接用存下来的密码走标准 AES 握手。
//  两者读出来的 firmwareVersion 都是同一位置的十进制两段式（主.次），
//  例：5.3 / 5.4。AAPS 的 EQUIL_SUPPORT_LEVEL = 5.3。
//

import Foundation

final class CmdDevicesGet: EquilBaseSetting {

    /// 固件版本字符串（"5.3"）。读不到时为空。
    private(set) var firmwareVersionText: String = ""
    /// 同上，数值形式，用于和 EQUIL_SUPPORT_LEVEL 比较。
    private(set) var firmwareVersion: Float = 0
    /// 回包里 data[6..7] 的数值（AAPS 只打日志，未解释含义）。
    private(set) var deviceValue: Int = 0

    // 与父类 EquilBaseCmd 的指定构造器签名一致，必须显式 override。
    override init(createTime: Int64, equilDevice: String, equilPassword: String) {
        super.init(createTime: createTime, equilDevice: equilDevice, equilPassword: equilPassword)
        self.port = "0000"
    }

    override var commandLabel: String { "设备信息查询 (CmdDevicesGet)" }

    override func getFirstData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data = EquilUtils.concat(indexByte, [0x02, 0x00])
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func getNextData() -> [UInt8]? {
        let indexByte = EquilUtils.intToBytes(EquilBaseCmd.pumpReqIndex)
        let data = EquilUtils.concat(indexByte, [0x00, 0x00, 0x01])
        EquilBaseCmd.pumpReqIndex += 1
        return data
    }

    override func decodeConfirmData(_ data: [UInt8]) {
        EquilBaseCmd.dlog("🔬 CmdDevicesGet confirm content=\(EquilUtils.bytesToHex(data)) (\(data.count)B)")
        guard data.count >= 20 else {
            // 载荷长度不够就只判成功，绝不瞎猜版本号 —— 猜出来的版本会直接
            // 影响 isSupport()，进而决定这台泵到底能不能用。
            EquilBaseCmd.dlog("🔬 CmdDevicesGet: content 只有 \(data.count)B，读不到固件版本")
            cmdSuccess = true
            return
        }
        deviceValue = (Int(data[7]) << 8) | Int(data[6])
        let fv = "\(Int(data[18])).\(Int(data[19]))"
        firmwareVersionText = fv
        firmwareVersion = Float(fv) ?? 0
        EquilBaseCmd.dlog("🔬 CmdDevicesGet: firmware=\(fv) value=\(deviceValue)")
        cmdSuccess = true
    }

    /// 与 AAPS 完全一致的判定：只有 SN 首字符属于 {0,1,3,A,D} 的老批次
    /// 才强制 ≥5.3，其余批次不看版本号。
    func isSupport(serialNumber: String) -> Bool {
        guard let firstChar = serialNumber.uppercased().first else { return true }
        let needsVersionCheck: Set<Character> = ["0", "1", "3", "A", "D"]
        if needsVersionCheck.contains(firstChar) {
            return firmwareVersion >= EquilConst.EQUIL_SUPPORT_LEVEL
        }
        return true
    }
}
