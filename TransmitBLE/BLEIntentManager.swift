import Foundation
import CoreBluetooth

enum BLEIntentError: Error, CustomLocalizedStringResourceConvertible {
    case bluetoothUnavailable
    case connectionTimeout
    case deviceNotFound
    case sendTimeout
    case noResponse

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .bluetoothUnavailable: return "Bluetooth is off or unauthorized."
        case .connectionTimeout:    return "Could not find Windows PC."
        case .deviceNotFound:       return "Lost connection before sending."
        case .sendTimeout:          return "No response from Windows."
        case .noResponse:           return "Windows sent unreadable data."
        }
    }
}

// One class, one job: connect → send → receive → done
// Runs entirely on a dedicated serial queue to avoid threading issues in Shortcuts
class BLEIntentManager: NSObject {

    static let shared = BLEIntentManager()

    // Serial queue — all BLE callbacks and state mutations happen here
    private let bleQueue = DispatchQueue(label: "ble.intent.queue")

    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?

    private let serviceUUID        = CBUUID(string: "12345678-1234-1234-1234-123456789abc")
    private let characteristicUUID = CBUUID(string: "abcdefab-cdef-abcd-efab-cdefabcdefab")

    // Single continuation that drives the entire flow
    private var completion: ((Result<String, Error>) -> Void)?
    private var pendingMessage: String?

    // State machine
    private enum State {
        case idle
        case waitingForBluetooth
        case scanning
        case connecting
        case discoveringServices
        case discoveringCharacteristics
        case subscribing
        case sending
        case waitingForResponse
    }
    private var state: State = .idle

    override init() {
        super.init()
        // IMPORTANT: init on bleQueue, no main queue — works correctly in Shortcuts background
        centralManager = CBCentralManager(delegate: self, queue: bleQueue)
    }

    // ── Public entry point called by SendToBLEIntent ──
    func send(_ message: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            bleQueue.async {
                // If already in a flow, fail fast
                guard self.state == .idle else {
                    continuation.resume(throwing: BLEIntentError.connectionTimeout)
                    return
                }

                self.pendingMessage = message
                self.completion = { result in
                    self.state = .idle
                    self.peripheral = nil
                    self.characteristic = nil
                    continuation.resume(with: result)
                }

                switch self.centralManager.state {
                case .poweredOn:
                    self.startScanning()
                case .poweredOff, .unauthorized, .unsupported:
                    self.finish(.failure(BLEIntentError.bluetoothUnavailable))
                default:
                    // .unknown or .resetting — wait for didUpdateState
                    self.state = .waitingForBluetooth
                    self.scheduleTimeout(seconds: 5, error: BLEIntentError.bluetoothUnavailable)
                }
            }
        }
    }

    private func startScanning() {
        state = .scanning
        centralManager.scanForPeripherals(withServices: [serviceUUID], options: nil)
        scheduleTimeout(seconds: 15, error: BLEIntentError.connectionTimeout)
    }

    private func finish(_ result: Result<String, Error>) {
        // Must be called on bleQueue
        centralManager.stopScan()
        if let p = peripheral {
            centralManager.cancelPeripheralConnection(p)
        }
        let cb = completion
        completion = nil
        cb?(result)
    }

    // Simple timeout using bleQueue after delay
    private func scheduleTimeout(seconds: Double, error: BLEIntentError) {
        let capturedState = state
        bleQueue.asyncAfter(deadline: .now() + seconds) {
            // Only fire if we're still in the same state (hasn't progressed)
            guard self.state == capturedState, self.completion != nil else { return }
            self.finish(.failure(error))
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEIntentManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Already on bleQueue
        guard state == .waitingForBluetooth else { return }
        switch central.state {
        case .poweredOn:
            startScanning()
        case .poweredOff, .unauthorized, .unsupported:
            finish(.failure(BLEIntentError.bluetoothUnavailable))
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard state == .scanning else { return }
        central.stopScan()
        self.peripheral = peripheral
        state = .connecting
        central.connect(peripheral, options: nil)
        scheduleTimeout(seconds: 10, error: BLEIntentError.connectionTimeout)
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        guard state == .connecting else { return }
        state = .discoveringServices
        peripheral.delegate = self
        peripheral.discoverServices([serviceUUID])
        scheduleTimeout(seconds: 10, error: BLEIntentError.connectionTimeout)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        finish(.failure(BLEIntentError.connectionTimeout))
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        if completion != nil {
            finish(.failure(BLEIntentError.connectionTimeout))
        }
    }
}

// MARK: - CBPeripheralDelegate
extension BLEIntentManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverServices error: Error?) {
        guard state == .discoveringServices else { return }
        if let error = error { finish(.failure(error)); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            finish(.failure(BLEIntentError.deviceNotFound)); return
        }
        state = .discoveringCharacteristics
        peripheral.discoverCharacteristics([characteristicUUID], for: service)
        scheduleTimeout(seconds: 10, error: BLEIntentError.connectionTimeout)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard state == .discoveringCharacteristics else { return }
        if let error = error { finish(.failure(error)); return }
        guard let char = service.characteristics?.first(where: { $0.uuid == characteristicUUID }) else {
            finish(.failure(BLEIntentError.deviceNotFound)); return
        }
        characteristic = char
        state = .subscribing
        peripheral.setNotifyValue(true, for: char)
        scheduleTimeout(seconds: 10, error: BLEIntentError.connectionTimeout)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard state == .subscribing else { return }
        if let error = error { finish(.failure(error)); return }

        // Subscribed — now send the message
        guard let message = pendingMessage,
              let data = message.data(using: .utf8),
              let char = self.characteristic else {
            finish(.failure(BLEIntentError.deviceNotFound)); return
        }
        state = .sending
        peripheral.writeValue(data, for: char, type: .withResponse)
        scheduleTimeout(seconds: 15, error: BLEIntentError.sendTimeout)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard state == .sending else { return }
        if let error = error { finish(.failure(error)); return }
        // Write confirmed — now wait for notification back from Windows
        state = .waitingForResponse
        scheduleTimeout(seconds: 15, error: BLEIntentError.sendTimeout)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard state == .waitingForResponse else { return }
        if let error = error { finish(.failure(error)); return }
        guard let data = characteristic.value,
              let string = String(data: data, encoding: .utf8) else {
            finish(.failure(BLEIntentError.noResponse)); return
        }
        finish(.success(string))
    }
}