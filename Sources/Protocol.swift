import Foundation

// MARK: - 帧层（LibFrame_Pack）
// 帧 = SOF SOF + 转义(body) + SOF SOF。SOF/ESC 由上层写入，默认 7E/7D，调试页可改。

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
            if b == sof || b == esc { out.append(esc) }
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
                out.append(raw[i + 1]); i += 2
            } else {
                out.append(b); i += 1
            }
        }
        return out
    }

    func pack(_ body: [UInt8]) -> [UInt8] { [sof, sof] + escape(body) + [sof, sof] }

    func stripFrames(_ stream: inout [UInt8]) -> [[UInt8]] {
        var result: [[UInt8]] = []
        while true {
            guard let start = marker(stream, from: 0) else {
                if stream.count > 4 { stream.removeFirst(stream.count - 4) }
                break
            }
            if start > 0 { stream.removeFirst(start) }
            guard stream.count > 4 else { break }
            guard let end = marker(stream, from: 2) else { break }
            result.append(unescape(Array(stream[2..<end])))
            stream.removeFirst(min(end + 2, stream.count))
        }
        return result
    }

    private func marker(_ bytes: [UInt8], from: Int) -> Int? {
        guard bytes.count >= 2 else { return nil }
        var i = from
        while i + 1 < bytes.count {
            if bytes[i] == sof && bytes[i + 1] == sof { return i }
            i += 1
        }
        return nil
    }
}

// MARK: - 消息层（EntityMessage）
// body = seq + addr + srcPort + dstPort + mode + param(2B) + len + data + crc(2B)
// len = data.count + 12（与 DevComm_Send 的 payloadLen+12 一致）

enum EquilMode: UInt8 {
    case set = 1
    case get = 2
}

struct EquilMessage {
    var dstAddress: UInt8
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
        var out: [UInt8] = []
        out.append(nextSeq())
        out.append(msg.dstAddress)
        out.append(msg.srcPort)
        out.append(msg.dstPort)
        out.append(msg.mode.rawValue)
        out.append(UInt8(msg.parameter & 0xFF))
        out.append(UInt8((msg.parameter >> 8) & 0xFF))
        out.append(UInt8(min(255, msg.data.count + 12)))
        out.append(contentsOf: msg.data)
        let crc = EquilCodec.crc16(out)
        out.append(UInt8(crc & 0xFF))
        out.append(UInt8((crc >> 8) & 0xFF))
        return out
    }

    func frame(for msg: EquilMessage) -> [UInt8] { codec.pack(body(for: msg)) }

    func describe(_ body: [UInt8]) -> String {
        guard body.count >= 8 else { return "短帧 \(body.count)B" }
        var parts = [
            "seq=\(body[0])",
            "addr=\(body[1])",
            "port=\(body[2])→\(body[3])",
            "mode=\(body[4])",
            "param=\(UInt16(body[5]) | (UInt16(body[6]) << 8))",
            "len=\(Int(body[7]))"
        ]
        if body.count >= 10 {
            var payload = Array(body[8..<(body.count - 2)])
            if payload.count > 10 { payload = Array(payload.prefix(10)) }
            parts.append("data=" + payload.map { String(format: "%02X", $0) }.joined())
            let calc = EquilCodec.crc16(Array(body[0..<(body.count - 2)]))
            let got = UInt16(body[body.count - 2]) | (UInt16(body[body.count - 1]) << 8)
            parts.append(calc == got ? "crc OK" : "crc ✗(\(String(format: "%04X", calc))/\(String(format: "%04X", got)))")
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - 字节工具

enum EquilByte {
    static func i32(_ v: Int) -> [UInt8] { i32(Int32(clamping: v)) }
    static func i32(_ v: Int32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
    static func u16(_ v: Int) -> [UInt8] {
        let x = UInt16(truncatingIfNeeded: max(0, min(65535, v)))
        return [UInt8(x & 0xFF), UInt8((x >> 8) & 0xFF)]
    }
    static func readI32(_ d: [UInt8], _ o: Int) -> Int32 {
        guard o + 3 < d.count else { return 0 }
        return Int32(d[o]) | Int32(d[o + 1]) << 8 | Int32(d[o + 2]) << 16 | Int32(d[o + 3]) << 24
    }
    static func readU16(_ d: [UInt8], _ o: Int) -> Int {
        guard o + 1 < d.count else { return 0 }
        return Int(d[o]) | Int(d[o + 1]) << 8
    }
    static func bcd(_ value: Int) -> UInt8 {
        let hi = (value / 10) % 10
        let lo = value % 10
        return UInt8((hi << 4) | lo)
    }
}

// MARK: - 实体（严格对应 com.microtechmd.library.entity.*）

/// EntityDevice: 6B id(hex) + endian + type + model(int32) + version(int32) + capacity(int32) = 20B
struct EquilDeviceInfo {
    var idHex: String
    var endian: UInt8
    var type: UInt8
    var model: Int32
    var version: Int32
    var capacity: Int32

    static func parse(_ d: [UInt8]) -> EquilDeviceInfo? {
        guard d.count >= 20 else { return nil }
        let id = Array(d[0..<6]).map { String(format: "%02X", $0) }.joined()
        return EquilDeviceInfo(
            idHex: id,
            endian: d[6],
            type: d[7],
            model: EquilByte.readI32(d, 8),
            version: EquilByte.readI32(d, 12),
            capacity: EquilByte.readI32(d, 16)
        )
    }

    func bytes(model: Int32) -> [UInt8] {
        var idBytes: [UInt8] = []
        let chars = Array(idHex.uppercased())
        var i = 0
        while i + 1 < chars.count && idBytes.count < 6 {
            let hi = UInt8(String(chars[i]), radix: 16) ?? 0
            let lo = UInt8(String(chars[i + 1]), radix: 16) ?? 0
            idBytes.append((hi << 4) | lo)
            i += 2
        }
        while idBytes.count < 6 { idBytes.append(0xFF) }
        return idBytes + [endian, type] + EquilByte.i32(model) + EquilByte.i32(version) + EquilByte.i32(capacity)
    }

    var description: String {
        "ID \(idHex) · 型号 \(model) · 固件 \(version) · 容量 \(capacity)"
    }
}

/// EntityHistory: 6B BCD 时间 + 电量 + 药量 + 基础率step(u16) + 大剂量step(u16) + 事件(index u16/port/type/level/data) = 18B
struct EquilHistory {
    var year = 0, month = 0, day = 0, hour = 0, minute = 0, second = 0
    var battery = 0
    var reservoir = 0
    var basalStep = 0
    var bolusStep = 0
    var eventIndex = 0
    var eventPort = 0
    var eventType = 0
    var eventLevel = 0
    var eventData = 0

    static func parse(_ d: [UInt8]) -> EquilHistory? {
        guard d.count >= 18 else { return nil }
        var h = EquilHistory()
        func bcdValue(_ b: UInt8) -> Int { Int(b & 0x0F) + Int(b >> 4) * 10 }
        h.year = 2000 + bcdValue(d[0])
        h.month = bcdValue(d[1])
        h.day = bcdValue(d[2])
        h.hour = bcdValue(d[3])
        h.minute = bcdValue(d[4])
        h.second = bcdValue(d[5])
        h.battery = Int(d[6])
        h.reservoir = Int(d[7])
        h.basalStep = Int(d[8]) | (Int(d[9]) << 8)
        h.bolusStep = Int(d[10]) | (Int(d[11]) << 8)
        h.eventIndex = Int(d[12]) | (Int(d[13]) << 8)
        h.eventPort = Int(d[14])
        h.eventType = Int(d[15])
        h.eventLevel = Int(d[16])
        h.eventData = Int(d[17])
        return h
    }

    var basalRateUnitsPerHour: Double { Double(basalStep) * 0.00625 }
    var bolusRateUnitsPerHour: Double { Double(bolusStep) * 0.00625 }
    var timeText: String { String(format: "%02d:%02d:%02d", hour, minute, second) }
    var dateText: String { String(format: "%04d-%02d-%02d", year, month, day) }

    var eventText: String {
        let level: String
        switch eventLevel {
        case 2: level = "报警"
        case 1: level = "警报"
        default: level = "通知"
        }
        return eventType == 0 ? "无事件" : "\(level)·类型\(eventType)·值\(eventData)·序号\(eventIndex)"
    }
}

/// Setting: 2×int32 + 6×short = 16B；单位类字段内部为 mU（回读 ×25/4）
struct EquilSetting {
    var expirationHours: Int32 = 0
    var autoOffHours: Int32 = 0
    var reservoirLow = 0
    var quickBolusStep = 0
    var occlusionLimit = 0
    var unitAmount = 0
    var basalRateLimit = 0
    var bolusAmountLimit = 0

    static func parse(_ d: [UInt8]) -> EquilSetting? {
        guard d.count >= 16 else { return nil }
        var s = EquilSetting()
        s.expirationHours = EquilByte.readI32(d, 0)
        s.autoOffHours = EquilByte.readI32(d, 4)
        s.reservoirLow = EquilByte.readU16(d, 8) * 25 / 4
        s.quickBolusStep = EquilByte.readU16(d, 10) * 25 / 4
        s.occlusionLimit = EquilByte.readU16(d, 12)
        s.unitAmount = EquilByte.readU16(d, 14) * 25 / 4
        if d.count >= 20 {
            s.basalRateLimit = EquilByte.readU16(d, 16) * 25 / 4
            s.bolusAmountLimit = EquilByte.readU16(d, 18) * 25 / 4
        }
        return s
    }

    func bytes() -> [UInt8] {
        EquilByte.i32(expirationHours)
            + EquilByte.i32(autoOffHours)
            + EquilByte.u16(reservoirLow * 4 / 25)
            + EquilByte.u16(quickBolusStep * 4 / 25)
            + EquilByte.u16(occlusionLimit)
            + EquilByte.u16(unitAmount * 4 / 25)
            + EquilByte.u16(basalRateLimit * 4 / 25)
            + EquilByte.u16(bolusAmountLimit * 4 / 25)
    }

    var description: String {
        "到期 \(expirationHours)h · 自动关 \(autoOffHours)h · 药量低限 \(reservoirLow)mU · 单次量 \(unitAmount)mU · 基础率上限 \(basalRateLimit)mU/h · 大剂量上限 \(bolusAmountLimit)mU"
    }
}

// MARK: - 命令层（对应 PresenterSystem / PresenterDelivery / PresenterMonitor）

struct EquilCommands {
    // 系统：端口 0→0
    static func queryDevice(address: UInt8) -> EquilMessage {
        EquilMessage(dstAddress: address, srcPort: 0, dstPort: 0, mode: .get, parameter: 0, data: EquilByte.i32(0))
    }

    /// 写绑定密码：用查询回来的 20B 设备信息，替换 model(int32) 后回写
    static func setDeviceModel(address: UInt8, info: EquilDeviceInfo, model: Int32) -> EquilMessage {
        EquilMessage(dstAddress: address, srcPort: 0, dstPort: 0, mode: .set, parameter: 0, data: info.bytes(model: model))
    }

    // 投递：端口 4→4
    static func queryMode(address: UInt8) -> EquilMessage {
        EquilMessage(dstAddress: address, srcPort: 4, dstPort: 4, mode: .get, parameter: 0, data: EquilByte.i32(0))
    }

    static func setMode(address: UInt8, mode: Int) -> EquilMessage {
        EquilMessage(dstAddress: address, srcPort: 4, dstPort: 4, mode: .set, parameter: 0, data: EquilByte.i32(mode))
    }

    static func queryBasal(address: UInt8) -> EquilMessage {
        EquilMessage(dstAddress: address, srcPort: 4, dstPort: 4, mode: .get, parameter: 2, data: [])
    }

    /// 48 个半小时槽，单位 mU/h；低于 50 mU 的相邻两槽合并到后一槽（复刻 ProfileBasal.setAmount）
    static func setBasal(address: UInt8, amounts: [Int]) -> EquilMessage {
        var slot = Array(amounts.prefix(48))
        if slot.isEmpty { slot = [0] }
        while slot.count < 48 { slot.append(slot[slot.count - 1]) }
        var merged = slot
        var i = 0
        while i < 47 {
            if merged[i] < 50 && merged[i + 1] < 50 {
                merged[i + 1] = merged[i] + merged[i + 1]
                merged[i] = 0
                i += 1
            }
            i += 1
        }
        var data: [UInt8] = []
        for v in merged { data.append(contentsOf: EquilByte.u16(v * 4 / 50)) }
        return EquilMessage(dstAddress: address, srcPort: 4, dstPort: 4, mode: .set, parameter: 2, data: data)
    }

    static func constantBasal(address: UInt8, unitsPerHour: Double) -> EquilMessage {
        let mu = Int(unitsPerHour * 1000)
        return setBasal(address: address, amounts: Array(repeating: mu, count: 48))
    }

    /// 大剂量 16B：amount0、interval0、amount1、interval1（内部 = mU×4/25）
    static func setBolus(address: UInt8, totalMiliUnits: Int, extendedMiliUnits: Int = 0, extendedSeconds: Int = 0) -> EquilMessage {
        let total = ((totalMiliUnits + 24) / 25) * 25
        let ext = min(max(0, extendedMiliUnits), total)
        let extRounded = ((ext + 24) / 25) * 25
        let now = total - extRounded
        let data = EquilByte.i32(extRounded * 4 / 25)
            + EquilByte.i32(extendedSeconds)
            + EquilByte.i32(now * 4 / 25)
            + EquilByte.i32(0)
        return EquilMessage(dstAddress: address, srcPort: 4, dstPort: 4, mode: .set, parameter: 3, data: data)
    }

    static func queryBolus(address: UInt8) -> EquilMessage {
        EquilMessage(dstAddress: address, srcPort: 4, dstPort: 4, mode: .get, parameter: 3, data: [])
    }

    static func stopBolus(address: UInt8) -> EquilMessage {
        EquilMessage(dstAddress: address, srcPort: 4, dstPort: 4, mode: .set, parameter: 3,
                     data: EquilByte.i32(0) + EquilByte.i32(0) + EquilByte.i32(0) + EquilByte.i32(0))
    }

    /// 临时率 8B：amount、interval；百分比用符号位翻转（对应 Java 的 percent - Integer.MIN_VALUE）
    static func setTempPercent(address: UInt8, percent: Int, seconds: Int) -> EquilMessage {
        let amount: Int32 = percent > 0 ? Int32(bitPattern: UInt32(percent) ^ 0x80000000) : 0
        let data = EquilByte.i32(amount) + EquilByte.i32(seconds)
        return EquilMessage(dstAddress: address, srcPort: 4, dstPort: 4, mode: .set, parameter: 4, data: data)
    }

    /// 绝对临时率：amount 单位 mU/h，按 25 mU 取整后按小时折算
    static func setTempAbsolute(address: UInt8, miliUnitsPerHour: Int, seconds: Int) -> EquilMessage {
        let rounded = ((miliUnitsPerHour + 24) / 25) * 25
        let amount = (rounded * seconds) / 3600
        let data = EquilByte.i32(amount) + EquilByte.i32(seconds)
        return EquilMessage(dstAddress: address, srcPort: 4, dstPort: 4, mode: .set, parameter: 4, data: data)
    }

    static func cancelTemp(address: UInt8) -> EquilMessage {
        setTempPercent(address: address, percent: 0, seconds: 0)
    }

    static func queryTemp(address: UInt8) -> EquilMessage {
        EquilMessage(dstAddress: address, srcPort: 4, dstPort: 4, mode: .get, parameter: 4, data: [])
    }

    static func querySetting(address: UInt8) -> EquilMessage {
        EquilMessage(dstAddress: address, srcPort: 4, dstPort: 4, mode: .get, parameter: 5, data: [])
    }

    static func setSetting(address: UInt8, setting: EquilSetting) -> EquilMessage {
        EquilMessage(dstAddress: address, srcPort: 4, dstPort: 4, mode: .set, parameter: 5, data: setting.bytes())
    }

    static func rewind(address: UInt8, units: Double) -> EquilMessage {
        EquilMessage(dstAddress: address, srcPort: 4, dstPort: 4, mode: .set, parameter: 6,
                     data: EquilByte.i32(Int(units * 1000) * 4 / 25))
    }

    static func prime(address: UInt8, units: Double) -> EquilMessage {
        EquilMessage(dstAddress: address, srcPort: 4, dstPort: 4, mode: .set, parameter: 7,
                     data: EquilByte.i32(Int(units * 1000) * 4 / 25))
    }

    /// 阻塞检测：端口 4→21，get/param 2
    static func checkOcclusion(address: UInt8) -> EquilMessage {
        EquilMessage(dstAddress: address, srcPort: 4, dstPort: 21, mode: .get, parameter: 2, data: [])
    }

    // 监控：端口 5→5
    static func setDateTime(address: UInt8, date: Date = Date()) -> EquilMessage {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let data: [UInt8] = [
            EquilByte.bcd((c.year ?? 2000) % 100),
            EquilByte.bcd(c.month ?? 1),
            EquilByte.bcd(c.day ?? 1),
            EquilByte.bcd(c.hour ?? 0),
            EquilByte.bcd(c.minute ?? 0),
            EquilByte.bcd(c.second ?? 0)
        ]
        return EquilMessage(dstAddress: address, srcPort: 5, dstPort: 5, mode: .set, parameter: 0, data: data)
    }

    static func queryHistory(address: UInt8, index: Int = 0) -> EquilMessage {
        EquilMessage(dstAddress: address, srcPort: 5, dstPort: 5, mode: .get, parameter: 1, data: EquilByte.u16(index))
    }
}
