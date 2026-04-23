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
        case .bluetoothUnavailable: return "Bluetooth is not available or turned off."
        case .connectionTimeout:    return "Could not find Windows PC — make sure it is running and nearby."
        case .deviceNotFound:       return "Windows BLE peripheral not found."
        case .sendTimeout:          return "Sent the message but got no response in time."
        case .noResponse:           return "Windows did not send a response."
        }
    }
}

@MainActor
class BLEIntentManager: NSObject, ObservableObject {

    static let shared = BLEIntentManager()

    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?

    private let serviceUUID        = CBUUID(string: "12345678-1234-1234-1234-123456789abc")
    private let characteristicUUID = CBUUID(string: "abcdefab-cdef-abcd-efab-cdefabcdefab")

    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var responseContinuation: CheckedContinuation<String, Error>?

    private(set) var isConnected = false

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    func connectAndWait() async throws {
        guard centralManager.state == .poweredOn else {
            throw BLEIntentError.bluetoothUnavailable
        }

        try await withCheckedThrowingContinuation { continuation in
            connectContinuation = continuation
            centralManager.scanForPeripherals(withServices: [serviceUUID], options: nil)

            Task {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                if self.connectContinuation != nil {
                    self.centralManager.stopScan()
                    self.connectContinuation?.resume(throwing: BLEIntentError.connectionTimeout)
                    self.connectContinuation = nil
                }
            }
        }
    }

    func sendAndWait(_ message: String) async throws -> String {
        guard let peripheral = peripheral,
              let characteristic = characteristic else {
            throw BLEIntentError.deviceNotFound
        }
        guard let data = message.data(using: .utf8) else {
            throw BLEIntentError.sendTimeout
        }

        return try await withCheckedThrowingContinuation { continuation in
            responseContinuation = continuation
            peripheral.writeValue(data, for: characteristic, type: .withResponse)

            Task {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                if self.responseContinuation != nil {
                    self.responseContinuation?.resume(throwing: BLEIntentError.sendTimeout)
                    self.responseContinuation = nil
                }
            }
        }
    }
}

extension BLEIntentManager: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {}

    nonisolated func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        Task { @MainActor in
            self.peripheral = peripheral
            central.stopScan()
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.isConnected = true
            peripheral.delegate = self
            peripheral.discoverServices([self.serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        Task { @MainActor in
            self.connectContinuation?.resume(throwing: BLEIntentError.connectionTimeout)
            self.connectContinuation = nil
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        Task { @MainActor in
            self.isConnected = false
            self.peripheral = nil
            self.characteristic = nil
        }
    }
}

extension BLEIntentManager: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard let services = peripheral.services else { return }
            for service in services where service.uuid == self.serviceUUID {
                peripheral.discoverCharacteristics([self.characteristicUUID], for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        Task { @MainActor in
            guard let chars = service.characteristics else { return }
            for char in chars where char.uuid == self.characteristicUUID {
                self.characteristic = char
                peripheral.setNotifyValue(true, for: char)
                self.connectContinuation?.resume()
                self.connectContinuation = nil
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        Task { @MainActor in
            if let error = error {
                self.responseContinuation?.resume(throwing: error)
                self.responseContinuation = nil
                return
            }
            guard let data = characteristic.value,
                  let string = String(data: data, encoding: .utf8) else {
                self.responseContinuation?.resume(throwing: BLEIntentError.noResponse)
                self.responseContinuation = nil
                return
            }
            self.responseContinuation?.resume(returning: string)
            self.responseContinuation = nil
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        Task { @MainActor in
            if let error = error {
                self.responseContinuation?.resume(throwing: error)
                self.responseContinuation = nil
            }
        }
    }
}