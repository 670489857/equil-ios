//
//  EquilUtils.swift
//  EquilKit
//
//  Byte-azonos port: AndroidAPS pump/equil manager/Utils.kt
//  Mérvadó forrás: nightscout/AndroidAPS (AGPL-3.0)
//
//  KRITIKUS: az intToBytes LITTLE-ENDIAN (LSB elöl). Ez a bólusz step/stepTime
//  kódolásának alapja. A korábbi (Cursor) port itt vagy a CRC byte-sorrendnél
//  romolhatott el — ezt unit teszt rögzíti.
//

import Foundation

enum EquilUtils {

    /// Utils.generateRandomPassword — kriptográfiailag biztonságos véletlen byte-ok.
    static func generateRandomPassword(_ length: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return bytes
    }

    /// Utils.intToBytes — 4 byte LITTLE-ENDIAN (src[0] = LSB).
    static func intToBytes(_ value: Int) -> [UInt8] {
        let v = UInt32(truncatingIfNeeded: value)
        return [
            UInt8(v & 0xFF),
            UInt8((v >> 8) & 0xFF),
            UInt8((v >> 16) & 0xFF),
            UInt8((v >> 24) & 0xFF)
        ]
    }

    /// Utils.bytes2Int — 4 byte little-endian → Int.
    static func bytes2Int(_ bytes: [UInt8]) -> Int {
        let int1 = Int(bytes[0]) & 0xFF
        let int2 = (Int(bytes[1]) & 0xFF) << 8
        let int3 = (Int(bytes[2]) & 0xFF) << 16
        let int4 = (Int(bytes[3]) & 0xFF) << 24
        return int1 | int2 | int3 | int4
    }

    /// Utils.intToTwoBytes — 2 byte little-endian.
    static func intToTwoBytes(_ value: Int) -> [UInt8] {
        let v = UInt32(truncatingIfNeeded: value)
        return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
    }

    /// Utils.bytesToInt — high/low byte, 0x8000 wrap.
    static func bytesToInt(_ highByte: UInt8, _ lowByte: UInt8) -> Int {
        let highValue = (Int(highByte) & 0xFF) << 8
        let lowValue = Int(lowByte) & 0xFF
        let value = highValue | lowValue
        if value >= 0x8000 {
            return value - 0x8000
        }
        return value
    }

    /// Utils.decodeSpeedToUH(Double) -> Int — bazál sebesség lépésekre.
    /// AAPS: BigDecimal(i) / 0.00625 (RoundingMode lefelé, mert toInt csonkol).
    static func decodeSpeedToUH(_ i: Double) -> Int {
        // BigDecimal pontos osztás; Double-lel a /0.00625 = *160
        // 0.00625 = 1/160, így i/0.00625 = i*160. Egész csonkítás.
        let exact = (Decimal(i) / Decimal(string: "0.00625")!)
        return NSDecimalNumber(decimal: exact).intValue
    }

    /// Utils.basalToByteArray — BIG-endian 2 byte (result[0]=hi).
    static func basalToByteArray(_ v: Double) -> [UInt8] {
        let value = decodeSpeedToUH(v)
        return [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    /// Utils.basalToByteArray2 — LITTLE-endian 2 byte (result[0]=lo).
    static func basalToByteArray2(_ v: Double) -> [UInt8] {
        let value = decodeSpeedToUH(v)
        return [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    /// Utils.hexStringToBytes — kisbetűt is kezel (uppercase-eli).
    static func hexStringToBytes(_ hex: String) -> [UInt8] {
        let hexString = hex.uppercased()
        let chars = Array(hexString)
        let length = chars.count / 2
        var d = [UInt8](repeating: 0, count: length)
        let lut = "0123456789ABCDEF"
        func charToByte(_ c: Character) -> Int {
            lut.distance(of: c) ?? 0
        }
        for i in 0..<length {
            let pos = i * 2
            let hi = charToByte(chars[pos])
            let lo = charToByte(chars[pos + 1])
            d[i] = UInt8((hi << 4) | lo)
        }
        return d
    }

    /// Utils.concat — bytearray-ek összefűzése.
    static func concat(_ arrays: [UInt8]...) -> [UInt8] {
        var result: [UInt8] = []
        for a in arrays { result.append(contentsOf: a) }
        return result
    }

    /// Utils.bytesToHex — uppercase hex string.
    static func bytesToHex(_ bytes: [UInt8]) -> String {
        let hexArray = Array("0123456789ABCDEF")
        var chars = [Character](repeating: "0", count: bytes.count * 2)
        for (j, byte) in bytes.enumerated() {
            let v = Int(byte) & 0xFF
            chars[j * 2] = hexArray[v >> 4]
            chars[j * 2 + 1] = hexArray[v & 0x0F]
        }
        return String(chars)
    }

    static func bytesToHex(_ data: Data) -> String {
        bytesToHex([UInt8](data))
    }

    // MARK: - 广播名 → 序列号
    //
    //  AAPS 的 CmdPair 只做 `name.replace("Equil - ", "")`，说明它认定的广播名格式
    //  只有一种。实际固件至少有 Equil-A1B2C3、Equil - A1B2C3、Equil_A1B2C3、
    //  甚至纯 A1B2C3 这几种写法；按固定字符串替换会漏掉其中一半，sn 里混进
    //  "Equil" 字样后 convertString 出来的十六进制长度不对，AES 密钥直接算错，
    //  泵只会回 ERROR_PWD，界面上表现为「密码错误」——排查起来非常费劲。
    //
    //  这里改成先剥前缀、再校验 6 位十六进制。解析失败返回 nil，调用方保留原名字，
    //  行为与 AAPS 一致。

    /// 从蓝牙广播名里解析 6 位序列号。解析不出返回 nil。
    static func parseSerial(from advertisedName: String) -> String? {
        var s = advertisedName.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. 剥掉厂商前缀：Equil / EQUIL / Equil- / Equil_ / Equil: 后面跟可选分隔符
        if let r = s.range(of: "^equil", options: [.regularExpression, .caseInsensitive]) {
            s = String(s[r.upperBound...])
        }
        // 2. 剥掉紧邻的分隔符
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " -_:#·"))
        // 3. 有些固件会把名字写成 "A1B2C3-Equil"，反过来也要认
        if let r = s.range(of: "equil$", options: [.regularExpression, .caseInsensitive]) {
            s = String(s[..<r.lowerBound])
                .trimmingCharacters(in: CharacterSet(charactersIn: " -_:#·"))
        }

        s = s.uppercased()
        // AAPS 只认 6 位十六进制，因为它的泵只有 A1B2C3 这一种。
        // 实测还有 P22505DC78 这种 10 位、含 P 的序列号（固件直接把整串广播出来）。
        // 放宽到 6–12 位大写字母数字：解析只用于显示和版本门槛判断，
        // 配对命令用的是原始广播名，这里放宽不会改变下发给泵的字节。
        guard (6...12).contains(s.count),
              s.range(of: "^[0-9A-Z]{6,12}$", options: .regularExpression) != nil else {
            return nil
        }
        return s
    }

    /// 把广播名规范化成 AAPS 认得的 `Equil - XXXXXX`。
    /// 解析不出 SN 时原样返回——交给泵去拒绝，总好过自己瞎猜一个序列号。
    static func canonicalName(from advertisedName: String) -> String {
        guard let sn = parseSerial(from: advertisedName) else {
            return advertisedName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "Equil - \(sn)"
    }
}

private extension String {
    /// Egy karakter indexe a stringben (a charToByte LUT-hoz).
    func distance(of character: Character) -> Int? {
        guard let idx = firstIndex(of: character) else { return nil }
        return distance(from: startIndex, to: idx)
    }
}
