import SwiftUI
import CoreBluetooth

// ── Must match Windows exactly ──
let SERVICE_UUID        = CBUUID(string: "12345678-1234-1234-1234-123456789abc")
let CHARACTERISTIC_UUID = CBUUID(string: "abcdefab-cdef-abcd-efab-cdefabcdefab")

// ─────────────────────────────────────────────
//  BLE Manager
// ─────────────────────────────────────────────
class BLEManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var dataCharacteristic: CBCharacteristic?

    @Published var status: String = "Initializing..."
    @Published var receivedData: String = ""
    @Published var isConnected: Bool = false

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    func startScan() {
        guard centralManager.state == .poweredOn else {
            status = "Bluetooth not ready"
            return
        }
        status = "Scanning for Windows device..."
        centralManager.scanForPeripherals(withServices: [SERVICE_UUID], options: nil)
    }

    func requestData() {
        guard let characteristic = dataCharacteristic else {
            status = "Not connected yet"
            return
        }
        peripheral?.readValue(for: characteristic)
        status = "Requesting data..."
    }

    func disconnect() {
        if let p = peripheral {
            centralManager.cancelPeripheralConnection(p)
        }
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:    status = "Bluetooth ready. Tap Scan."
        case .poweredOff:   status = "Bluetooth is off"
        case .unauthorized: status = "Bluetooth unauthorized — check Settings"
        default:            status = "Bluetooth unavailable"
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        self.peripheral = peripheral
        centralManager.stopScan()
        status = "Found device. Connecting..."
        centralManager.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        status = "Connected! Discovering services..."
        isConnected = true
        peripheral.delegate = self
        peripheral.discoverServices([SERVICE_UUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        status = "Disconnected"
        isConnected = false
        self.peripheral = nil
        dataCharacteristic = nil
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        status = "Failed to connect: \(error?.localizedDescription ?? "unknown")"
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == SERVICE_UUID {
            status = "Service found. Discovering characteristics..."
            peripheral.discoverCharacteristics([CHARACTERISTIC_UUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for char in characteristics where char.uuid == CHARACTERISTIC_UUID {
            dataCharacteristic = char
            if char.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: char)
            }
            status = "Ready. Tap 'Request Data'."
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            status = "Read error: \(error.localizedDescription)"
            return
        }
        guard let data = characteristic.value,
              let string = String(data: data, encoding: .utf8) else {
            status = "Received unreadable data"
            return
        }
        receivedData = string
        status = "Data received!"
    }
}

// ─────────────────────────────────────────────
//  SwiftUI View
// ─────────────────────────────────────────────
struct ContentView: View {
    @StateObject private var ble = BLEManager()

    var body: some View {
        VStack(spacing: 24) {
            Text("BLE Client")
                .font(.largeTitle).bold()

            Text(ble.status)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            GroupBox("Received from Windows") {
                Text(ble.receivedData.isEmpty ? "Nothing yet" : ble.receivedData)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                    .padding(4)
            }
            .padding(.horizontal)

            HStack(spacing: 16) {
                Button("Scan") {
                    ble.startScan()
                }
                .buttonStyle(.borderedProminent)
                .disabled(ble.isConnected)

                Button("Request Data") {
                    ble.requestData()
                }
                .buttonStyle(.bordered)
                .disabled(!ble.isConnected)

                Button("Disconnect") {
                    ble.disconnect()
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(!ble.isConnected)
            }
        }
        .padding()
    }
}

//	 FIX: replaced #Preview (Xcode 15+ only) with PreviewProvider (works on all versions)
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
