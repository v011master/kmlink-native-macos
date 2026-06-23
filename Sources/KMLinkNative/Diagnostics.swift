import Foundation

enum Diagnostics {
    static func render(
        device: USBDeviceSnapshot,
        accessibilityTrusted: Bool,
        clipboardSummary: String,
        inputSummary: String,
        bridge: OTiBridge
    ) -> String {
        """
        KMLink Native diagnostics
        generated: \(ISO8601DateFormatter().string(from: Date()))

        device.connected: \(device.isConnected)
        device.vendorID: \(String(format: "%04X", device.vendorID))
        device.productID: \(String(format: "%04X", device.productID))
        device.productName: \(device.productName ?? "nil")
        device.serialNumber: \(device.serialNumber ?? "nil")
        device.locationID: \(device.locationID.map(String.init) ?? "nil")

        accessibility.trusted: \(accessibilityTrusted)
        input: \(inputSummary)
        clipboard.last: \(clipboardSummary)
        bridge.status: \(bridge.statusLine)

        \(bridge.transportDiagnostics)
        """
    }

    static func write(_ text: String) {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/KMLinkNative", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("diagnostics.txt")
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            NSLog("KMLinkNative diagnostics failed: \(error.localizedDescription)")
        }
    }
}
