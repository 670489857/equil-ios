import Foundation

// 微泰 Equil 链路层：帧 = SOF SOF + 转义(body) + SOF SOF
// body = seq + addr + srcPort + dstPort + mode + param(2B) + len(1B) + data + crc(2B)
// 这些常量来自对 libjni_interface.so 的逆向（LibFrame_Pack / TaskComm_Send / DevComm_Send），
// 若首次联调无回帧，可在「调试」页直接改 SOF/ESC 或粘贴原始 HEX 发送。

struct EquilCodec {
    var sof: UInt8 = 0x7E
    var esc: UInt8 = 0x7D

    static func crc16(_ bytes: [UInt8], initial: UInt16 = 0xFFFF) -> UInt16 {
        var crc = initial
        for b in bytes {
            let idx = Int((crc & 0xFF) ^ UInt16(b))
            crc = (crc >> 8) ^ EquilCodec.table[idx]
        }
        return crc
    }

    // CRC-16/MODBUS 反射表（多项式 0xA001）
    static let table: [UInt16] = {
        var t = [UInt16](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt16(i)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? (c >> 1) ^ 0xA001 : (c >> 1)
            }
            t[i] = c
        }
        return t
    }()

    func escape(_ body: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(body.count + 8)
        for b in body {
            if b == sof || b == esc {
                out.append(esc)
            }
            out.append(b)
        }
        return out
    }

    func unescape(_ raw: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < raw.count {
            let b = raw[i]
            if b == esc, i + 1 < raw.count {
                out.append(raw[i + 1])
                i += 2
            } else {
                out.append(b)
                i += 1
            }
        }
        return out
    }

    func pack(_ body: [UInt8]) -> [UInt8] {
        [sof, sof] + escape(body) + [sof, sof]
    }

    // 从字节流中按 SOF SOF … SOF SOF 切帧，返回已去转义的 body
    func extractFrames(from stream: inout [UInt8]) -> [[UInt8]] {
        var result: [[UInt8]] = []
        while true {
            guard let start = indexOfMarker(stream, from: 0) else {
                if stream.count > 4 { stream.removeFirst(stream.count - 4) }
                break
            }
            if start > 0 { stream.removeFirst(start) }
            guard stream.count > 4 else { break }
            let searchFrom = 2
            guard let end = indexOfMarker(stream, from: searchFrom) else { break }
            let inner = Array(stream[2..<end])
            result.append(unescape(inner))
            stream.removeFirst(min(end + 2, stream.count))
        }
        return result
    }

    private func indexOfMarker(_ bytes: [UInt8], from: Int) -> Int? {
        guard bytes.count >= 2 else { return nil }
        var i = from
        while i + 1 < bytes.count {
            if bytes[i] == sof && bytes[i + 1] == sof { return i }
            i += 1
        }
        return nil
    }
}

enum EquilMode: UInt8 {
    case set = 1
    case get = 2
}

struct EquilMessage {
    var srcAddress: UInt8 = 9
    var dstAddress: UInt8 = 0
    var srcPort: UInt8
    var dstPort: UInt8
    var mode: EquilMode
    var parameter: UInt16
    var data: [UInt8]
}

final class EquilProtocol {
    static let shared = EquilProtocol()

    var codec = EquilCodec()
    private var seq: UInt8 = 0

    private func nextSeq() -> UInt8 {
        seq += 1
        if seq == 0 || seq > 0x3F { seq = 1 }
        return seq
    }

    func body(for msg: EquilMessage) -> [UInt8] {
        let total = UInt8(min(255, msg.data.count + 12))
        var out: [UInt8] = []
        out.append(nextSeq())
        out.append(msg.dstAddress)
        out.append(msg.srcPort)
        out.append(msg.dstPort)
        out.append(msg.mode.rawValue)
        out.append(UInt8(msg.parameter & 0xFF))
        out.append(UInt8((msg.parameter >> 8) & 0xFF))
        out.append(total)
        out.append(contentsOf: msg.data)
        let crc = EquilCodec.crc16(out)
        out.append(UInt8(crc & 0xFF))
        out.append(UInt8((crc >> 8) & 0xFF))
        return out
    }

    func frame(for msg: EquilMessage) -> [UInt8] {
        codec.pack(body(for: msg))
    }

    func describe(_ body: [UInt8]) -> String {
        guard body.count >= 8 else { return "短帧 \(body.count)B" }
        let len = Int(body[7])
        var parts = [
            "seq=\(body[0])",
            "addr=\(body[1])",
            "port=\(body[2])→\(body[3])",
            "mode=\(body[4])",
            "param=\(UInt16(body[5]) | (UInt16(body[6]) << 8))",
            "len=\(len)"
        ]
        if body.count >= 10 {
            var payload = Array(body[8..<(body.count - 2)])
            if payload.count > 8 { payload = Array(payload.prefix(8)) }
            parts.append("data=" + payload.map { String(format: "%02X", $0) }.joined())
        }
        if body.count >= 10 {
            let calc = EquilCodec.crc16(Array(body[0..<(body.count - 2)]))
            let got = UInt16(body[body.count - 2]) | (UInt16(body[body.count - 1]) << 8)
            parts.append(calc == got ? "crc OK" : "crc 不符(算\(String(format: "%04X", calc)) 收\(String(format: "%04X", got)))")
        }
        return parts.joined(separator: " ")
    }
}

// 业务命令：端口/操作码/数据格式严格复刻 com.microtechmd.library.presenter.*
struct EquilCommands {
    static func int32(_ v: Int) -> [UInt8] {
        let clamped = max(Int(Int32.min), min(Int(Int32.max), v))
        return bytes32(Int32(clamped))
    }

    static func bytes32(_ v: Int32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    static func queryDevice(address: UInt8) -> EquilMessage {
        EquilMessage(dstAddress: address, srcPort: 0, dstPort: 0, mode: .get, parameter: 0, data: int32(0))
    }

    static func bindPassword(address: UInt8, password: [UInt8]) -> EquilMessage {
        // EntityDevice.model 为泵内密码，20 字节
        var pwd = password
        while pwd.count < 20 { pwd.append(0) }
        return EquilMessage(dstAddress: address, srcPort: 0, dstPort: 0, mode: .set, parameter: 0, data: Array(pwd.prefix(20)))
    }

    static func queryMode(address: UInt8) -> EquilMessage {
        EquilMessage(dstAddress: address, srcPort: 4, dstPort: 4, mode: .get, parameter: 0, data: [])
    }

    static func setMode(address: UInt8, mode: Int) -> EquilMessage {
        // 0 暂停 1 运行 2 停止
        EquilMessage(dstAddress: address, srcPort: 4, dstPort: 4, mode: .set, parameter: 0, data: int32(mode))
    }

    static func queryBasalProfile(address: UInt8) -> EquilMessage {
        EquilMessage(dstAddress: address, srcPort: 4, dstPort: 4, mode: .get, parameter: 2, data: [])
    }

    static func queryBolusProfile(address: UInt8) -> EquilMessage {
        EquilMessage(dstAddress: address, srcPort: 4, dstPort: 4, mode: .get, parameter: 3, data: [])
    }

    static func queryTempProfile(address: UInt8) -> EquilMessage {
        EquilMessage(dstAddress: address, srcPort: 4, dstPort: 4, mode: .get, parameter: 4, data: [])
    }

    // 大剂量：amountTotal/amountExtended 单位 mU；intervalExtended 秒
    static func setBolus(address: UInt8, amountTotal: Int, amountExtended: Int, intervalExtended: Int) -> EquilMessage {
        let total = ((amountTotal + 24) / 25) * 25
        let ext = max(0, amountExtended)
        let extRounded = ((min(total, ext) + 24) / 25) * 25
        let now = total - extRounded
        let data = int32((extRounded * 4) / 25) + int32(0) + int32(intervalExtended) + int32((now * 4) / 25)
        return EquilMessage(dstAddress: address, srcPort: 4, dstPort: 4, mode: .set, parameter: 3, data: data)
    }

    // 临时基础率：percent 为百分比，interval 为秒；percent=0 表示取消
    static func setTempPercent(address: UInt8, percent: Int, intervalSeconds: Int) -> EquilMessage {
        // 原实现 percent -= Integer.MIN_VALUE（Java 溢出语义 = 翻转符号位）
        let amount: Int32 = percent > 0 ? Int32(bitPattern: UInt32(percent) ^ 0x80000000) : 0
        let data = bytes32(amount) + int32(intervalSeconds)
        return EquilMessage(dstAddress: address, srcPort: 4, dstPort: 4, mode: .set, parameter: 4, data: data)
    }

    static func cancelTemp(address: UInt8) -> EquilMessage {
        setTempPercent(address: address, percent: 0, intervalSeconds: 0)
    }

    static func stopBolus(address: UInt8) -> EquilMessage {
        EquilMessage(dstAddress: address, srcPort: 4, dstPort: 4, mode: .set, parameter: 3, data: int32(0) + int32(0) + int32(0) + int32(0))
    }

    static func rewind(address: UInt8, units: Double) -> EquilMessage {
        EquilMessage(dstAddress: address, srcPort: 4, dstPort: 4, mode: .set, parameter: 6, data: int32(Int(units * 1000 * 4 / 25)))
    }

    static func prime(address: UInt8, units: Double) -> EquilMessage {
        EquilMessage(dstAddress: address, srcPort: 4, dstPort: 4, mode: .set, parameter: 7, data: int32(Int(units * 1000 * 4 / 25)))
    }

    static func queryHistory(address: UInt8, index: Int) -> EquilMessage {
        // EntityNumber(dataType: short, value: index)
        EquilMessage(dstAddress: address, srcPort: 5, dstPort: 5, mode: .get, parameter: 1,
                     data: EquilNumber.short(1, index))
    }
}

enum EquilNumber {
    // EntityNumber(dataType:short, value) -> 2 字节小端
    static func short(_ dataType: Int, _ value: Int) -> [UInt8] {
        let v = UInt16(truncatingIfNeeded: value)
        return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
    }
}
