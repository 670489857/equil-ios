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
    @Published var logs: [String] = []
    @Published var lastFrameHex: String = ""
    @Published var frames: [String] = []
    @Published var characteristics: [CBCharacteristic] = []

    private var central: CBCentralManager!
    private var found: [UUID: Discovered] = [:]

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
        found.removeAll()
        devices = []
        scanning = true
        central.scanForPeripherals(withServices: nil, options: nil)
        log("开始扫描")
    }

    func stopScan() {
        central.stopScan()
        scanning = false
        log("停止扫描")
    }

    func connect(_ item: Discovered) {
        central.stopScan()
        scanning = false
        connected = item.peripheral
        connectedName = item.name
        item.peripheral.delegate = self
        central.connect(item.peripheral, options: nil)
        log("连接 \(item.name) \(item.peripheral.identifier.uuidString)")
    }

    func disconnect() {
        if let p = connected {
            central.cancelPeripheralConnection(p)
        }
    }

}

extension BLEManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        poweredOn = central.state == .poweredOn
        log("蓝牙状态 \(central.state.rawValue)")
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
        log("已连接，开始发现服务")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("连接失败 \(error?.localizedDescription ?? "-")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("断开连接 \(error?.localizedDescription ?? "")")
        connected = nil
        connectedName = ""
        characteristics = []
    }
}

extension BLEManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error { log("发现服务失败 \(error.localizedDescription)") }
        for service in peripheral.services ?? [] {
            log("服务 \(service.uuid.uuidString)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for ch in service.characteristics ?? [] {
            log("特征 \(ch.uuid.uuidString) 属性 \(ch.properties.rawValue)")
            characteristics.append(ch)
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
