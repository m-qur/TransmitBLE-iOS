import AppIntents

struct SendToBLEIntent: AppIntent {

    static var title: LocalizedStringResource = "Send to Windows via BLE"
    static var description = IntentDescription("Sends text to the Windows PC over BLE and returns the response.")

    @Parameter(title: "Message", description: "The text to send to Windows")
    var message: String

    @MainActor
    func perform() async throws -> some ReturnsValue<String> & ProvidesDialog {
        let manager = BLEIntentManager.shared

        if !manager.isConnected {
            try await manager.connectAndWait()
        }

        let response = try await manager.sendAndWait(message)

        return .result(
            value: response,
            dialog: "\(response)"
        )
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