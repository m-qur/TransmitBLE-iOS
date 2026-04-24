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

final class BLEIntentManager: NSObject {

    static let shared = BLEIntentManager()

    private let bleQueue = DispatchQueue(label: "ble.intent.queue")

    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?

    private let serviceUUID = CBUUID(string: "12345678-1234-1234-1234-123456789abc")
    private let characteristicUUID = CBUUID(string: "abcdefab-cdef-abcd-efab-cdefabcdefab")

    private var completion: ((Result<String, Error>) -> Void)?
    private var pendingMessage: String?

    private var operationID = UUID()
    private var didFinish = false

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
        centralManager = CBCentralManager(delegate: self, queue: bleQueue)
    }

    func send(_ message: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            bleQueue.async {

                guard self.state == .idle else {
                    continuation.resume(throwing: BLEIntentError.connectionTimeout)
                    return
                }

                self.state = .idle
                self.didFinish = false
                self.operationID = UUID()

                let currentID = self.operationID

                self.pendingMessage = message

                self.completion = { result in
                    self.bleQueue.async {
                        guard self.operationID == currentID else { return }
                        self.finish(result)
                        continuation.resume(with: result)
                    }
                }

                switch self.centralManager.state {
                case .poweredOn:
                    self.startScanning()
                case .poweredOff, .unauthorized, .unsupported:
                    continuation.resume(throwing: BLEIntentError.bluetoothUnavailable)
                default:
                    self.state = .waitingForBluetooth
                    self.scheduleTimeout(seconds: 5, error: BLEIntentError.bluetoothUnavailable, id: currentID)
                }
            }
        }
    }

    private func startScanning() {
        state = .scanning
        centralManager.scanForPeripherals(withServices: [serviceUUID], options: nil)
        scheduleTimeout(seconds: 15, error: BLEIntentError.connectionTimeout, id: operationID)
    }

    private func finish(_ result: Result<String, Error>) {
        guard !didFinish else { return }
        didFinish = true

        centralManager.stopScan()

        if let p = peripheral {
            centralManager.cancelPeripheralConnection(p)
        }

        let cb = completion
        completion = nil
        cb?(result)
    }

    private func scheduleTimeout(seconds: Double, error: BLEIntentError, id: UUID) {
        let capturedState = state

        bleQueue.asyncAfter(deadline: .now() + seconds) {
            guard self.operationID == id else { return }
            guard self.state == capturedState else { return }
            guard self.completion != nil else { return }

            self.finish(.failure(error))
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEIntentManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
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

        scheduleTimeout(seconds: 10, error: BLEIntentError.connectionTimeout, id: operationID)
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {

        guard state == .connecting else { return }

        state = .discoveringServices
        peripheral.delegate = self
        peripheral.discoverServices([serviceUUID])

        scheduleTimeout(seconds: 10, error: BLEIntentError.connectionTimeout, id: operationID)
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

        if error != nil {
            finish(.failure(error!))
            return
        }

        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            finish(.failure(BLEIntentError.deviceNotFound))
            return
        }

        state = .discoveringCharacteristics
        peripheral.discoverCharacteristics([characteristicUUID], for: service)

        scheduleTimeout(seconds: 10, error: BLEIntentError.connectionTimeout, id: operationID)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {

        guard state == .discoveringCharacteristics else { return }

        if error != nil {
            finish(.failure(error!))
            return
        }

        guard let char = service.characteristics?.first(where: { $0.uuid == characteristicUUID }) else {
            finish(.failure(BLEIntentError.deviceNotFound))
            return
        }

        characteristic = char
        state = .subscribing
        peripheral.setNotifyValue(true, for: char)

        scheduleTimeout(seconds: 10, error: BLEIntentError.connectionTimeout, id: operationID)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {

        guard error == nil else {
            finish(.failure(error!))
            return
        }

        guard let message = pendingMessage,
              let data = message.data(using: .utf8),
              let char = self.characteristic else {
            finish(.failure(BLEIntentError.deviceNotFound))
            return
        }

        state = .sending
        peripheral.writeValue(data, for: char, type: .withResponse)

        scheduleTimeout(seconds: 15, error: BLEIntentError.sendTimeout, id: operationID)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {

        guard error == nil else {
            finish(.failure(error!))
            return
        }

        state = .waitingForResponse

        scheduleTimeout(seconds: 15, error: BLEIntentError.sendTimeout, id: operationID)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {

        guard completion != nil else { return }

        if let error = error {
            finish(.failure(error))
            return
        }

        guard let data = characteristic.value,
              let string = String(data: data, encoding: .utf8) else {
            finish(.failure(BLEIntentError.noResponse))
            return
        }

        finish(.success(string))
    }
}