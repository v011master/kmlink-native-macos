import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let deviceMonitor = USBDeviceMonitor()
    private let accessibility = AccessibilityMonitor()
    private let clipboard = ClipboardMonitor()
    private let bridge = OTiBridge()
    private let eventTap = EventTapMonitor()
    private let hidTransport = OTiHIDTransport()

    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private var hidTestStatus = "HID Test: idle"
    private var clipboardSendStatus = "Clipboard TX: idle"
    private var clipboardReceiveStatus = "Clipboard RX: idle"
    private var clipboardAutoSendEnabled = false
    private var clipboardAutoReceiveEnabled = false
    private var clipboardSendInFlight = false
    private var clipboardReceiveInFlight = false
    private var suppressNextClipboardAutoSend = false
    private var pendingClipboardText: String?
    private var clipboardAutoReceiveTimer: Timer?
    private var clipboardLastTransportSummary = "Clipboard Transport: idle"
    private var clipboardHistory: [String] = []
    private var lastClipboardSentPreview = "none"
    private var lastClipboardLogPath = "none"

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "KM"
        statusItem.button?.toolTip = "KMLink Native"
        statusItem.menu = statusMenu

        rebuildMenu()

        deviceMonitor.onChange = { [weak self] snapshot in
            self?.bridge.updateDevice(snapshot)
            self?.rebuildMenu()
        }

        clipboard.onChange = { [weak self] summary in
            self?.bridge.noteClipboardChange(summary)
            if self?.suppressNextClipboardAutoSend == true {
                self?.suppressNextClipboardAutoSend = false
            } else if self?.clipboardAutoSendEnabled == true, let text = ClipboardMonitor.currentText(), !text.isEmpty {
                self?.queueClipboardSend(text)
            }
            self?.rebuildMenu()
        }

        eventTap.onChange = { [weak self] in
            self?.rebuildMenu()
        }
        eventTap.onEvent = { [weak self] event, type in
            self?.hidTransport.enqueue(event: event, type: type)
        }

        hidTransport.onChange = { [weak self] in
            self?.rebuildMenu()
        }

        deviceMonitor.start()
        clipboard.start()
        _ = accessibility.refresh(prompt: false)
        eventTap.startIfTrusted()
    }

    private func rebuildMenu() {
        let snapshot = deviceMonitor.snapshot
        let trusted = accessibility.isTrusted
        let bridgeState = bridge.statusLine

        DispatchQueue.main.async {
            self.statusItem.button?.title = snapshot.isConnected ? "KM On" : "KM"
            self.statusMenu.removeAllItems()

            self.statusMenu.addItem(.disabled("KMLink Native"))
            self.statusMenu.addItem(.disabled(snapshot.statusLine))
            self.statusMenu.addItem(.disabled(trusted ? "Accessibility: granted" : "Accessibility: missing"))
            self.statusMenu.addItem(.disabled(self.eventTap.statusLine))
            self.statusMenu.addItem(.disabled(self.hidTransport.statusLine))
            self.statusMenu.addItem(.disabled(self.hidTestStatus))
            self.statusMenu.addItem(.disabled("Clipboard: \(self.clipboard.lastSummary)"))
            self.statusMenu.addItem(.disabled("Clipboard Auto-Send: \(self.clipboardAutoSendEnabled ? "on" : "off")"))
            self.statusMenu.addItem(.disabled("Clipboard Auto-Receive: \(self.clipboardAutoReceiveEnabled ? "on" : "off")"))
            self.statusMenu.addItem(.disabled(self.clipboardSendStatus))
            self.statusMenu.addItem(.disabled(self.clipboardReceiveStatus))
            self.statusMenu.addItem(.disabled("Clipboard Last TX: \(self.lastClipboardSentPreview)"))
            self.statusMenu.addItem(.disabled("Clipboard Last Log: \(self.lastClipboardLogName)"))
            self.statusMenu.addItem(.disabled(self.clipboardLastTransportSummary))
            for entry in self.clipboardHistory.prefix(3) {
                self.statusMenu.addItem(.disabled(entry))
            }
            self.statusMenu.addItem(.disabled(bridgeState))
            self.statusMenu.addItem(.separator())

            self.statusMenu.addItem(
                NSMenuItem(
                    title: "Enable Mirrored Forwarding",
                    action: #selector(self.enableMirroredForwarding),
                    keyEquivalent: ""
                ).targeting(self)
            )

            self.statusMenu.addItem(
                NSMenuItem(
                    title: "Enable Remote-Only Forwarding",
                    action: #selector(self.enableRemoteOnlyForwarding),
                    keyEquivalent: ""
                ).targeting(self)
            )

            self.statusMenu.addItem(
                NSMenuItem(
                    title: "Disable Remote Input Forwarding",
                    action: #selector(self.disableRemoteInputForwarding),
                    keyEquivalent: ""
                ).targeting(self)
            )

            self.statusMenu.addItem(
                NSMenuItem(
                    title: "Type Test Text to Remote",
                    action: #selector(self.typeTestTextToRemote),
                    keyEquivalent: ""
                ).targeting(self)
            )

            self.statusMenu.addItem(
                NSMenuItem(
                    title: "Left Click Test to Remote",
                    action: #selector(self.leftClickTestToRemote),
                    keyEquivalent: ""
                ).targeting(self)
            )

            self.statusMenu.addItem(
                NSMenuItem(
                    title: "Scroll Test to Remote",
                    action: #selector(self.scrollTestToRemote),
                    keyEquivalent: ""
                ).targeting(self)
            )

            self.statusMenu.addItem(
                NSMenuItem(
                    title: "Send Clipboard to Remote",
                    action: #selector(self.sendClipboardToRemote),
                    keyEquivalent: ""
                ).targeting(self)
            )

            self.statusMenu.addItem(
                NSMenuItem(
                    title: "Send Clipboard to Remote (Native Probe)",
                    action: #selector(self.sendClipboardToRemoteNativeProbe),
                    keyEquivalent: ""
                ).targeting(self)
            )

            self.statusMenu.addItem(
                NSMenuItem(
                    title: "Send Clipboard Test Token",
                    action: #selector(self.sendClipboardTestToken),
                    keyEquivalent: ""
                ).targeting(self)
            )

            self.statusMenu.addItem(
                NSMenuItem(
                    title: self.clipboardAutoSendEnabled ? "Disable Clipboard Auto-Send" : "Enable Clipboard Auto-Send",
                    action: #selector(self.toggleClipboardAutoSend),
                    keyEquivalent: ""
                ).targeting(self)
            )

            self.statusMenu.addItem(
                NSMenuItem(
                    title: "Receive Clipboard from Remote",
                    action: #selector(self.receiveClipboardFromRemote),
                    keyEquivalent: ""
                ).targeting(self)
            )

            self.statusMenu.addItem(
                NSMenuItem(
                    title: self.clipboardAutoReceiveEnabled ? "Disable Clipboard Auto-Receive" : "Enable Clipboard Auto-Receive",
                    action: #selector(self.toggleClipboardAutoReceive),
                    keyEquivalent: ""
                ).targeting(self)
            )

            self.statusMenu.addItem(
                NSMenuItem(
                    title: "Request Accessibility Permission",
                    action: #selector(self.requestAccessibility),
                    keyEquivalent: ""
                ).targeting(self)
            )

            self.statusMenu.addItem(
                NSMenuItem(
                    title: "Open Accessibility Settings",
                    action: #selector(self.openAccessibilitySettings),
                    keyEquivalent: ""
                ).targeting(self)
            )

            self.statusMenu.addItem(
                NSMenuItem(
                    title: "Write Diagnostics",
                    action: #selector(self.writeDiagnostics),
                    keyEquivalent: ""
                ).targeting(self)
            )

            self.statusMenu.addItem(.separator())
            self.statusMenu.addItem(
                NSMenuItem(
                    title: "Quit",
                    action: #selector(self.quit),
                    keyEquivalent: "q"
                ).targeting(self)
            )
        }
    }

    @objc private func requestAccessibility() {
        _ = accessibility.refresh(prompt: true)
        eventTap.startIfTrusted()
        rebuildMenu()
    }

    @objc private func enableMirroredForwarding() {
        eventTap.mode = .mirrored
        eventTap.startIfTrusted()
        rebuildMenu()
    }

    @objc private func enableRemoteOnlyForwarding() {
        eventTap.mode = .remoteOnly
        eventTap.startIfTrusted()
        rebuildMenu()
    }

    @objc private func disableRemoteInputForwarding() {
        eventTap.mode = .watching
        eventTap.startIfTrusted()
        rebuildMenu()
    }

    @objc private func typeTestTextToRemote() {
        hidTestStatus = "HID Test: typing KMLINK TEST"
        rebuildMenu()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = self?.hidTransport.sendASCIITextForDiagnostics("KMLINK TEST") ?? HIDTextResult(
                succeeded: false,
                attemptedCharacters: 0,
                sentReports: 0,
                failedReports: 0,
                unsupportedCharacters: "",
                lastSummary: "transport-unavailable"
            )
            DispatchQueue.main.async {
                self?.hidTestStatus = result.succeeded ? "HID Test: typed KMLINK TEST" : "HID Test: failed"
                self?.rebuildMenu()
            }
        }
    }

    @objc private func leftClickTestToRemote() {
        hidTestStatus = "HID Test: left click"
        rebuildMenu()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = self?.hidTransport.sendMouseLeftClickForDiagnostics() ?? HIDForwardBurstResult(
                sent: 0,
                failed: 1,
                elapsedMilliseconds: 0,
                lastSummary: "transport-unavailable"
            )
            DispatchQueue.main.async {
                self?.hidTestStatus = result.succeeded ? "HID Test: left click sent" : "HID Test: left click failed"
                self?.rebuildMenu()
            }
        }
    }

    @objc private func scrollTestToRemote() {
        hidTestStatus = "HID Test: scroll"
        rebuildMenu()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = self?.hidTransport.sendScrollForDiagnostics() ?? HIDForwardBurstResult(
                sent: 0,
                failed: 1,
                elapsedMilliseconds: 0,
                lastSummary: "transport-unavailable"
            )
            DispatchQueue.main.async {
                self?.hidTestStatus = result.succeeded ? "HID Test: scroll sent" : "HID Test: scroll failed"
                self?.rebuildMenu()
            }
        }
    }

    @objc private func sendClipboardToRemote() {
        guard let text = ClipboardMonitor.currentText(), !text.isEmpty else {
            clipboardSendStatus = "Clipboard TX: no text"
            rebuildMenu()
            return
        }

        clipboardSendStatus = "Clipboard TX: legacy sending \(text.count) chars"
        rebuildMenu()

        queueClipboardSendViaLegacyBridge(text)
    }

    @objc private func sendClipboardToRemoteNativeProbe() {
        guard let text = ClipboardMonitor.currentText(), !text.isEmpty else {
            clipboardSendStatus = "Clipboard TX: no text"
            rebuildMenu()
            return
        }

        clipboardSendStatus = "Clipboard TX: native sending \(text.count) chars"
        rebuildMenu()

        queueClipboardSend(text)
    }

    @objc private func sendClipboardTestToken() {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        let token = "KMLINK-TEST-\(formatter.string(from: Date()))"
        suppressNextClipboardAutoSend = true
        ClipboardMonitor.setText(token)
        clipboardSendStatus = "Clipboard TX: staging test token"
        lastClipboardSentPreview = ClipboardMonitor.preview(token)
        rebuildMenu()
        queueClipboardSendViaLegacyBridge(token)
    }

    @objc private func toggleClipboardAutoSend() {
        clipboardAutoSendEnabled.toggle()
        clipboardSendStatus = clipboardAutoSendEnabled ? "Clipboard TX: auto-send armed" : "Clipboard TX: auto-send off"
        rebuildMenu()
    }

    private func queueClipboardSend(_ text: String) {
        guard !clipboardSendInFlight else {
            pendingClipboardText = text
            clipboardSendStatus = "Clipboard TX: queued \(text.count) chars"
            rebuildMenu()
            return
        }

        clipboardSendInFlight = true
        pendingClipboardText = nil
        lastClipboardSentPreview = ClipboardMonitor.preview(text)
        clipboardSendStatus = "Clipboard TX: sending \(text.count) chars"
        rebuildMenu()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = OTiDataProbe.sendInitializedClipboardTextProbe(
                text,
                sendSwitchToRemoteNotify: false,
                includeClipboardCommandTerminator: false
            )
            DispatchQueue.main.async {
                self?.clipboardSendStatus = result.succeeded ? "Clipboard TX: sent \(text.count) chars" : "Clipboard TX: failed"
                self?.noteClipboardTransport(result.summary, prefix: result.succeeded ? "TX ok" : "TX fail")
                self?.clipboardSendInFlight = false
                self?.rebuildMenu()
                if let next = self?.pendingClipboardText {
                    self?.pendingClipboardText = nil
                    self?.queueClipboardSend(next)
                }
            }
        }
    }

    private func queueClipboardSendViaLegacyBridge(_ text: String) {
        guard !clipboardSendInFlight else {
            pendingClipboardText = text
            clipboardSendStatus = "Clipboard TX: queued \(text.count) chars"
            rebuildMenu()
            return
        }

        clipboardSendInFlight = true
        pendingClipboardText = nil
        suppressNextClipboardAutoSend = true
        lastClipboardSentPreview = ClipboardMonitor.preview(text)
        clipboardSendStatus = "Clipboard TX: legacy sending \(text.count) chars"
        rebuildMenu()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = LegacyClipboardBridge.sendText(text)
            DispatchQueue.main.async {
                self?.lastClipboardLogPath = result.logPath ?? "none"
                self?.clipboardSendStatus = result.succeeded ? "Clipboard TX: legacy sent \(text.count) chars" : "Clipboard TX: legacy failed"
                self?.noteClipboardTransport(result.summary, prefix: result.succeeded ? "TX legacy ok" : "TX legacy fail")
                self?.clipboardSendInFlight = false
                self?.rebuildMenu()
                if let next = self?.pendingClipboardText {
                    self?.pendingClipboardText = nil
                    self?.queueClipboardSendViaLegacyBridge(next)
                }
            }
        }
    }

    @objc private func receiveClipboardFromRemote() {
        queueClipboardReceive(isAutomatic: false)
    }

    @objc private func toggleClipboardAutoReceive() {
        clipboardAutoReceiveEnabled.toggle()
        if clipboardAutoReceiveEnabled {
            startClipboardAutoReceive()
            clipboardReceiveStatus = "Clipboard RX: auto-receive armed"
        } else {
            stopClipboardAutoReceive()
            clipboardReceiveStatus = "Clipboard RX: auto-receive off"
        }
        rebuildMenu()
    }

    private func startClipboardAutoReceive() {
        stopClipboardAutoReceive()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.queueClipboardReceive(isAutomatic: true)
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        clipboardAutoReceiveTimer = timer
    }

    private func stopClipboardAutoReceive() {
        clipboardAutoReceiveTimer?.invalidate()
        clipboardAutoReceiveTimer = nil
    }

    private func queueClipboardReceive(isAutomatic: Bool) {
        if isAutomatic, !deviceMonitor.snapshot.isConnected {
            return
        }

        if isAutomatic, clipboardSendInFlight {
            return
        }

        guard !clipboardReceiveInFlight else {
            if !isAutomatic {
                clipboardReceiveStatus = "Clipboard RX: already receiving"
                rebuildMenu()
            }
            return
        }

        clipboardReceiveInFlight = true
        clipboardReceiveStatus = isAutomatic ? "Clipboard RX: polling" : "Clipboard RX: receiving"
        rebuildMenu()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: OTiClipboardReceiveResult
            if isAutomatic {
                result = OTiDataProbe.receiveClipboardTextProbe(
                    maxPolls: 8,
                    pollIntervalMicroseconds: 350_000
                )
            } else {
                let legacy = LegacyClipboardBridge.receiveText()
                result = OTiClipboardReceiveResult(
                    succeeded: legacy.succeeded,
                    summary: legacy.summary,
                    clipboard: legacy.text.map {
                        ClipboardUPipeMessage.ReceivedClipboard(
                            command: "Cmd_Transfer_Clipboard",
                            format: .text,
                            text: $0,
                            contentBytes: $0.utf8.count
                        )
                    },
                    transport: OTiDataProbeResult(
                        succeeded: legacy.succeeded,
                        summary: legacy.summary,
                        data: []
                    )
                )
            }
            DispatchQueue.main.async {
                self?.clipboardReceiveInFlight = false
                if let clipboard = result.clipboard {
                    self?.suppressNextClipboardAutoSend = true
                    ClipboardMonitor.setText(clipboard.text)
                    self?.clipboardReceiveStatus = isAutomatic ? "Clipboard RX: auto-received \(clipboard.text.count) chars" : "Clipboard RX: received \(clipboard.text.count) chars"
                    self?.noteClipboardTransport(result.summary, prefix: isAutomatic ? "RX auto ok" : "RX ok")
                } else {
                    self?.clipboardReceiveStatus = result.succeeded
                        ? (isAutomatic ? "Clipboard RX: polling" : "Clipboard RX: no clipboard packet")
                        : "Clipboard RX: failed"
                    if !isAutomatic || !result.succeeded {
                        self?.noteClipboardTransport(result.summary, prefix: result.succeeded ? "RX no packet" : "RX fail")
                    }
                }
                self?.rebuildMenu()
            }
        }
    }

    private func noteClipboardTransport(_ summary: String, prefix: String) {
        let timestamp = DateFormatter.clipboardStatus.string(from: Date())
        let compact = summary.count > 96 ? "\(summary.prefix(96))..." : summary
        clipboardLastTransportSummary = "Clipboard Transport: \(prefix) \(timestamp)"
        clipboardHistory.insert("  \(prefix): \(compact)", at: 0)
        if clipboardHistory.count > 5 {
            clipboardHistory.removeLast(clipboardHistory.count - 5)
        }
    }

    @objc private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func writeDiagnostics() {
        let report = Diagnostics.render(
            device: deviceMonitor.snapshot,
            accessibilityTrusted: accessibility.isTrusted,
            clipboardSummary: appClipboardDiagnostics,
            inputSummary: eventTap.statusLine,
            bridge: bridge
        )
        Diagnostics.write(report)
        rebuildMenu()
    }

    @objc private func quit() {
        stopClipboardAutoReceive()
        NSApp.terminate(nil)
    }
}

private extension AppDelegate {
    var appClipboardDiagnostics: String {
        let history = clipboardHistory.isEmpty ? "none" : clipboardHistory.joined(separator: " | ")
        return "\(clipboard.lastSummary); send=\(clipboardSendStatus); receive=\(clipboardReceiveStatus); autoSend=\(clipboardAutoSendEnabled); autoReceive=\(clipboardAutoReceiveEnabled); lastTransport=\(clipboardLastTransportSummary); lastLog=\(lastClipboardLogPath); history=\(history)"
    }

    var lastClipboardLogName: String {
        if lastClipboardLogPath == "none" {
            return "none"
        }
        return URL(fileURLWithPath: lastClipboardLogPath).lastPathComponent
    }
}

private extension NSMenuItem {
    static func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    func targeting(_ target: AnyObject) -> NSMenuItem {
        self.target = target
        return self
    }
}

private extension DateFormatter {
    static let clipboardStatus: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
