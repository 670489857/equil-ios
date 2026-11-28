import Foundation
import CoreBluetooth

struct Discovered: Identifiable {
    let id: UUID
    let peripheral: CBPeripheral
    var name: String
    var rssi: Int
    var likelyPump: Bool
}

final class BLEManager: NSObject, ObservableObject {

    static let serviceUUIDs = [
        CBUUID(string: "0000F000-0000-1000-8000-00805F9B34FB"),
        CBUUID(string: "0000FFE0-0000-1000-8000-00805F9B34FB")
    ]

    @Published var poweredOn = false
    @Published var scanning = false
    @Published var devices: [Discovered] = []
    @Published var connected: CBPeripheral?
    @Published var connectedName: String = ""
    @Published var statusText: String = "未连接"
    @Published var errorText: String? = nil
    @Published var logs: [String] = []
    @Published var lastFrameHex: String = ""
    @Published var frames: [String] = []
    @Published var characteristics: [CBCharacteristic] = []
    @Published var serviceNames: [String] = []
    @Published var pumpServiceFound = false
    @Published var writableReady = false
    @Published var pumpMode: Int? = nil
    @Published var txCount = 0
    @Published var rxCount = 0

    private var central: CBCentralManager!
    private var found: [UUID: Discovered] = [:]
    private var timeoutTask: DispatchWorkItem?
    private var pendingDevice: Discovered?
    private var writeChar: CBCharacteristic?
    private var rxBuffer: [UInt8] = []

    var bindAddress: UInt8 = 0

    // 只显示名称以 EQ 开头的设备（大小写不敏感）
    @Published var onlyEqPrefix: Bool = (UserDefaults.standard.object(forKey: "only_eq") as? Bool) ?? true
    @Published var filteredCount = 0
    @Published var autoReconnect = true
    private var manualDisconnect = false
    private var reconnectTask: DispatchWorkItem?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func log(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "\(formatter.string(from: Date()))  \(text)"
        logs.insert(line, at: 0)
        if logs.count > 400 { logs.removeLast(logs.count - 400) }
    }

    func startScan() {
        guard poweredOn else { log("蓝牙未就绪"); return }
        errorText = nil
        found.removeAll()
        devices = []
        filteredCount = 0
        scanning = true
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        log("开始扫描")
    }

    func stopScan() {
        central.stopScan()
        scanning = false
        log("停止扫描")
    }

    func connect(_ item: Discovered) {
        errorText = nil
        pendingDevice = item
        central.stopScan()
        scanning = false
        if let old = connected { central.cancelPeripheralConnection(old) }
        connected = nil
        connectedName = item.name
        statusText = "正在连接 \(item.name)…"
        item.peripheral.delegate = self
        central.connect(item.peripheral, options: nil)
        log("连接 \(item.name)")

        timeoutTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self = self, self.connected == nil else { return }
            self.errorText = "连接超时（8 秒）。贴泵可能正被另一台手机（AAPS/原厂 App）连着，或已休眠。"
            self.statusText = "连接失败"
            self.log("连接超时")
            if let p = self.pendingDevice?.peripheral { self.central.cancelPeripheralConnection(p) }
        }
        timeoutTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: task)
    }

    func retry() {
        if let d = pendingDevice { connect(d) } else { startScan() }
    }

    func disconnect() {
        manualDisconnect = true
        reconnectTask?.cancel()
        timeoutTask?.cancel()
        if let p = connected { central.cancelPeripheralConnection(p) }
        connected = nil
        writeChar = nil
        writableReady = false
        statusText = "未连接"
        serviceNames = []
        characteristics = []
        pumpServiceFound = false
        pumpMode = nil
        rxBuffer = []
    }

    func setOnlyEqPrefix(_ value: Bool) {
        onlyEqPrefix = value
        UserDefaults.standard.set(value, forKey: "only_eq")
        found = found.filter { value ? $0.value.name.lowercased().hasPrefix("eq") : true }
        devices = found.values.sorted {
            if $0.likelyPump != $1.likelyPump { return $0.likelyPump }
            return $0.rssi > $1.rssi
        }
        log(value ? "只显示 EQ 开头的设备" : "显示全部设备")
    }

    func clearError() { errorText = nil }

    // MARK: - 发送

    @discardableResult
    func send(_ msg: EquilMessage) -> Bool {
        let frame = EquilProtocol.shared.frame(for: msg)
        log("TX msg port \(msg.srcPort)→\(msg.dstPort) mode \(msg.mode.rawValue) param \(msg.parameter)")
        return sendRaw(bytes: frame)
    }

    @discardableResult
    func sendRaw(hex: String) -> Bool {
        let cleaned = hex.uppercased().filter { "0123456789ABCDEF ".contains($0) }
        let parts = cleaned.split(separator: " ").compactMap { UInt8($0, radix: 16) }
        guard !parts.isEmpty else { log("HEX 格式不对"); return false }
        return sendRaw(bytes: parts)
    }

    @discardableResult
    private func sendRaw(bytes: [UInt8]) -> Bool {
        guard let peripheral = connected, let ch = writeChar else {
            errorText = "还没连上可写特征（F001/FFE1）"
            return false
        }
        let data = Data(bytes)
        let type: CBCharacteristicWriteType = ch.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(data, for: ch, type: type)
        txCount += 1
        log("TX \(bytes.count)B: \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
        return true
    }
}

extension BLEManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        poweredOn = central.state == .poweredOn
        log("蓝牙状态 \(central.state.rawValue)")
        if !poweredOn { statusText = "蓝牙不可用" }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
            ?? "(无名称)"
        let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let likely = uuids.contains { BLEManager.serviceUUIDs.contains($0) }
        if onlyEqPrefix && !name.lowercased().hasPrefix("eq") {
            if found[peripheral.identifier] == nil {
                filteredCount += 1
                if filteredCount <= 5 { log("跳过 \(name)（非 EQ 开头）") }
            }
            return
        }
        var item = Discovered(id: peripheral.identifier, peripheral: peripheral,
                             name: name, rssi: RSSI.intValue, likelyPump: likely)
        if let old = found[item.id], old.rssi >= item.rssi {
            item.rssi = old.rssi
            item.likelyPump = old.likelyPump || item.likelyPump
        }
        found[item.id] = item
        devices = found.values.sorted {
            if $0.likelyPump != $1.likelyPump { return $0.likelyPump }
            return $0.rssi > $1.rssi
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        timeoutTask?.cancel()
        connected = peripheral
        manualDisconnect = false
        connectedName = peripheral.name ?? pendingDevice?.name ?? ""
        statusText = "已连接，正在发现服务…"
        errorText = nil
        log("已连接，开始发现服务")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        timeoutTask?.cancel()
        connected = nil
        statusText = "连接失败"
        errorText = "连接失败：\(error?.localizedDescription ?? "未知原因")。贴泵若被其他手机占用，请先断开那台。"
        log("连接失败 \(error?.localizedDescription ?? "-")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        timeoutTask?.cancel()
        connected = nil
        writeChar = nil
        writableReady = false
        serviceNames = []
        characteristics = []
        pumpServiceFound = false
        pumpMode = nil
        statusText = "已断开"
        if let error = error {
            errorText = "连接中断：\(error.localizedDescription)"
        }
        log("断开连接 \(error?.localizedDescription ?? "")")
        if autoReconnect && !manualDisconnect, let device = pendingDevice {
            log("5 秒后自动重连")
            let task = DispatchWorkItem { [weak self] in
                guard let self = self, self.connected == nil else { return }
                self.connect(device)
            }
            reconnectTask?.cancel()
            reconnectTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: task)
        }
    }
}

extension BLEManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error { log("发现服务失败 \(error.localizedDescription)") }
        let services = peripheral.services ?? []
        serviceNames = services.map { $0.uuid.uuidString }
        pumpServiceFound = services.contains { BLEManager.serviceUUIDs.contains($0.uuid) }
        statusText = pumpServiceFound
            ? "已找到贴泵服务（\(services.count) 个）"
            : "已连接，但没找到 F000/FFE0 服务"
        if !pumpServiceFound {
            errorText = "这个设备没有微泰贴泵的服务 UUID，可能不是泵，或需要先唤醒贴泵。"
        }
        for service in services {
            log("服务 \(service.uuid.uuidString)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for ch in service.characteristics ?? [] {
            let p = ch.properties
            log("特征 \(ch.uuid.uuidString) 属性 \(p.rawValue)\(p.contains(.write) ? " 可写" : "")\(p.contains(.writeWithoutResponse) ? " 免响应" : "")")
            if !characteristics.contains(where: { $0.uuid == ch.uuid }) {
                characteristics.append(ch)
            }
            let writable = p.contains(.write) || p.contains(.writeWithoutResponse)
            if writable, writeChar == nil, ch.uuid.uuidString.hasPrefix("0000F001") {
                writeChar = ch
            } else if writable, writeChar == nil {
                writeChar = ch
            }
            if p.contains(.notify) || p.contains(.indicate) {
                peripheral.setNotifyValue(true, for: ch)
            }
        }
        writableReady = writeChar != nil
        if let ch = writeChar {
            statusText = "就绪，可下发命令"
            log("写入特征 \(ch.uuid.uuidString)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let data = characteristic.value else { return }
        rxCount += 1
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        lastFrameHex = hex
        frames.insert(hex, at: 0)
        if frames.count > 200 { frames.removeLast(frames.count - 200) }
        log("RX \(data.count)B: \(hex)")

        rxBuffer.append(contentsOf: [UInt8](data))
        let bodies = EquilProtocol.shared.codec.extractFrames(from: &rxBuffer)
        for body in bodies {
            log("帧解析 → \(EquilProtocol.shared.describe(body))")
            if body.count >= 12, body[2] == 4, body[3] == 4,
               (UInt16(body[5]) | UInt16(body[6]) << 8) == 0 {
                let value = Int(body[8]) | Int(body[9]) << 8 | Int(body[10]) << 16 | Int(body[11]) << 24
                if value >= 0 && value <= 2 { pumpMode = value }
            }
        }
    }
}
