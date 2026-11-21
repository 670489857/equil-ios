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

    private var central: CBCentralManager!
    private var found: [UUID: Discovered] = [:]
    private var timeoutTask: DispatchWorkItem?
    private var pendingDevice: Discovered?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func log(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "\(formatter.string(from: Date()))  \(text)"
        logs.insert(line, at: 0)
        if logs.count > 300 { logs.removeLast(logs.count - 300) }
    }

    func startScan() {
        guard poweredOn else { log("蓝牙未就绪"); return }
        errorText = nil
        found.removeAll()
        devices = []
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
        log("连接 \(item.name) \(item.peripheral.identifier.uuidString)")

        timeoutTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self = self, self.connected == nil else { return }
            self.errorText = "连接超时（8 秒）。常见原因：贴泵正被另一台手机（AAPS/原厂 App）连着，或泵已休眠。"
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
        timeoutTask?.cancel()
        if let p = connected { central.cancelPeripheralConnection(p) }
        connected = nil
        statusText = "未连接"
        serviceNames = []
        characteristics = []
        pumpServiceFound = false
    }

    func clearError() { errorText = nil }
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
        errorText = "连接失败：\(error?.localizedDescription ?? "未知原因")。若贴泵正被其他手机占用，请先断开那台。"
        log("连接失败 \(error?.localizedDescription ?? "-")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        timeoutTask?.cancel()
        connected = nil
        serviceNames = []
        characteristics = []
        pumpServiceFound = false
        statusText = "已断开"
        if let error = error {
            errorText = "连接中断：\(error.localizedDescription)"
        }
        log("断开连接 \(error?.localizedDescription ?? "")")
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
            log("特征 \(ch.uuid.uuidString) 属性 \(ch.properties.rawValue)")
            if !characteristics.contains(where: { $0.uuid == ch.uuid }) {
                characteristics.append(ch)
            }
            if ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: ch)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let data = characteristic.value else { return }
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        lastFrameHex = hex
        frames.insert(hex, at: 0)
        if frames.count > 200 { frames.removeLast(frames.count - 200) }
        log("收到帧 \(data.count)B: \(hex)")
    }
}
