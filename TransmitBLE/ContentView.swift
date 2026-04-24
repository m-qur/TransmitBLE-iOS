import SwiftUI
import CoreBluetooth

let SERVICE_UUID        = CBUUID(string: "12345678-1234-1234-1234-123456789abc")
let CHARACTERISTIC_UUID = CBUUID(string: "abcdefab-cdef-abcd-efab-cdefabcdefab")

// ─────────────────────────────────────────────
//  BLE Manager (used by the UI)
// ─────────────────────────────────────────────
class BLEManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var dataCharacteristic: CBCharacteristic?

    @Published var status: String = "Initializing..."
    @Published var response: String = ""
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
        status = "Scanning..."
        centralManager.scanForPeripherals(withServices: [SERVICE_UUID], options: nil)
    }

    func sendData(_ text: String) {
        guard let peripheral = peripheral,
              let characteristic = dataCharacteristic else {
            status = "Not connected"
            return
        }
        guard let data = text.data(using: .utf8) else { return }
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
        status = "Sent! Waiting for response..."
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
        status = "Device Found. Connecting..."
        centralManager.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        status = "Connected! Setting up..."
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
        status = "Failed: \(error?.localizedDescription ?? "unknown")"
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == SERVICE_UUID {
            peripheral.discoverCharacteristics([CHARACTERISTIC_UUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for char in characteristics where char.uuid == CHARACTERISTIC_UUID {
            dataCharacteristic = char
            peripheral.setNotifyValue(true, for: char)
            status = "Ready. Type something and tap Send."
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            status = "Error: \(error.localizedDescription)"
            return
        }
        guard let data = characteristic.value,
              let string = String(data: data, encoding: .utf8) else {
            status = "Unreadable response"
            return
        }
        response = string
        status = "Response received!"
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            status = "Write failed: \(error.localizedDescription)"
        }
    }
}

// ─────────────────────────────────────────────
//  SwiftUI View
// ─────────────────────────────────────────────
struct ContentView: View {
    @StateObject private var ble = BLEManager()
    @State private var userInput: String = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("TransmitBLE")
                .font(.largeTitle).bold()

            Text(ble.status)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            TextField("Type your message...", text: $userInput)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .disabled(!ble.isConnected)

            Button("Send") {
                ble.sendData(userInput)
                userInput = ""
            }
            .buttonStyle(.borderedProminent)
            .disabled(!ble.isConnected || userInput.isEmpty)

            GroupBox("Response") {
                Text(ble.response.isEmpty ? "Nothing yet..." : ble.response)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                    .padding(4)
            }
            .padding(.horizontal)

            HStack(spacing: 16) {
                Button("Scan") {
                    ble.startScan()
                }
                .buttonStyle(.bordered)
                .disabled(ble.isConnected)

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

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}