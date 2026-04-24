import AppIntents
import SwiftUI

struct SendToBLEIntent: AppIntent {

    static var title: LocalizedStringResource = "Send to Windows via BLE"
    static var description = IntentDescription("Sends text to the Windows PC over BLE and returns the response.")

    static var openAppWhenRun: Bool = true

    @Parameter(title: "Message", description: "The text to send to Windows")
    var message: String

    func perform() async throws -> some ReturnsValue<String> {
        let response = try await BLEIntentManager.shared.send(message)
        return .result(value: response)
    }
}

struct TransmitBLEShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendToBLEIntent(),
            phrases: [
                "Send BLE message with \(.applicationName)",
                "Transmit to Windows with \(.applicationName)"
            ],
            shortTitle: "Send to Windows",
            systemImageName: "antenna.radiowaves.left.and.right"
        )
    }
}