import Foundation

final class OTiBridge {
    private var device: USBDeviceSnapshot = .disconnected
    private var transport: TransportProbeSnapshot = .empty
    private var lastClipboardSummary = "none"

    var statusLine: String {
        guard device.isConnected else {
            return "Bridge: waiting for OTi USB device"
        }

        return "\(transport.statusLine); \(lastClipboardSummary)"
    }

    var transportDiagnostics: String {
        transport.diagnostics
    }

    func updateDevice(_ snapshot: USBDeviceSnapshot) {
        device = snapshot
        transport = TransportProbe.currentSnapshot()
    }

    func noteClipboardChange(_ summary: String) {
        lastClipboardSummary = "clipboard=\(summary)"
    }
}
