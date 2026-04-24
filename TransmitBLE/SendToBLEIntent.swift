import AppIntents
import SwiftUI

struct SendToBLEIntent: AppIntent {

    static var title: LocalizedStringResource = "Send to Windows via BLE"
    static var description = IntentDescription("Sends text to the Windows PC over BLE and returns the response.")

    // THIS IS THE KEY FIX:
    // openAppWhenRun = true forces Shortcuts to bring the app to the foreground
    // before running the intent — this makes BLE scanning work because
    // the app is now in the foreground, not a dead background process
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Message", description: "The text to send to Windows")
    var message: String

    func perform() async throws -> some ReturnsValue<String> & ProvidesDialog {
        let response = try await BLEIntentManager.shared.send(message)
        return .result(value: response, dialog: "\(response)")
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