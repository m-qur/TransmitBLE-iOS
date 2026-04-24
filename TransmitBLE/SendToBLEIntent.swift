import AppIntents
import SwiftUI

struct SendToBLEIntent: AppIntent {

    static var title: LocalizedStringResource = "Ask via BLE"
    static var description = IntentDescription("Gets response via BLE")

    static var openAppWhenRun: Bool = true

    @Parameter(title: "Message", description: "Input to send")
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
                "Send BLE message via \(.applicationName)",
                "Transmit via BLE with \(.applicationName)"
            ],
            shortTitle: "Send to Device",
            systemImageName: "antenna.radiowaves.left.and.right"
        )
    }
}