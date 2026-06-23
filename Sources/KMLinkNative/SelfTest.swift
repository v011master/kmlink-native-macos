import Foundation

enum SelfTest {
    static func run() -> Int32 {
        let accessibility = AccessibilityMonitor()
        _ = accessibility.refresh(prompt: false)
        let eventTap = EventTapMonitor()
        eventTap.startIfTrusted()
        let eventTapStatus = eventTap.statusLine
        let eventTapRunning = eventTap.isRunning
        eventTap.stop()

        let device = USBDeviceMonitor.currentSnapshot()
        let transport = TransportProbe.currentSnapshot()
        let hidTransport = OTiHIDTransport()
        let hid = hidTransport.sendKeyboardReleaseForDiagnostics()
        let hidBurst = hidTransport.sendKeyboardReleaseBurstForDiagnostics(count: 5)
        let clipboardSample = "KMLink Native clipboard self-test\nLine two"
        let clipboardEncoded = ClipboardUPipeMessage.encodeTextGoBridgeCommand(clipboardSample)
        let clipboardFrame = clipboardEncoded.frames.first ?? []
        let clipboardHeader = ClipboardUPipeMessage.commandDataHeaderValues(from: clipboardFrame) ?? []
        let clipboardExpectedText = "KMLink Native clipboard self-test\r\nLine two"
        let clipboardDecoded = ClipboardUPipeMessage.clipboardText(fromReceivedPacket: clipboardFrame)
        let clipboardLengthField = ClipboardUPipeMessage.commandXMLLength(from: clipboardEncoded.commandBytes)
        let clipboardCommandXMLBytes = max(0, clipboardEncoded.commandBytes.count - 5)

        var checks: [SelfTestCheck] = []
        checks.append(SelfTestCheck(
            name: "usb.device",
            passed: device.isConnected,
            detail: device.statusLine
        ))
        checks.append(SelfTestCheck(
            name: "accessibility.trusted",
            passed: accessibility.isTrusted,
            detail: accessibility.isTrusted ? "granted" : "missing"
        ))
        checks.append(SelfTestCheck(
            name: "input.tap",
            passed: eventTapRunning,
            detail: eventTapStatus
        ))
        checks.append(SelfTestCheck(
            name: "scsi.inquiry",
            passed: transport.scsiInquiry.best != nil,
            detail: transport.scsiInquiry.statusLine
        ))

        let successfulVendorCommands = transport.vendorCommands.attempts.filter(\.succeeded).count
        checks.append(SelfTestCheck(
            name: "vendor.read",
            passed: successfulVendorCommands >= 2,
            detail: "\(successfulVendorCommands)/\(transport.vendorCommands.attempts.count) read probes ok; \(transport.vendorCommands.preparation)"
        ))
        checks.append(SelfTestCheck(
            name: "hid.release",
            passed: hid.succeeded,
            detail: hid.summary
        ))
        checks.append(SelfTestCheck(
            name: "hid.sessionReuse",
            passed: hidBurst.succeeded && hidBurst.sent == 5,
            detail: hidBurst.summary
        ))
        checks.append(SelfTestCheck(
            name: "clipboard.gobridgeEncode",
            passed: ClipboardUPipeMessage.validateFrames(clipboardEncoded.frames)
                && clipboardEncoded.commandID == 0x39
                && clipboardLengthField == UInt32(clipboardCommandXMLBytes)
                && clipboardHeader.count == 5
                && clipboardHeader[2] == 0
                && clipboardHeader[3] == UInt32(clipboardEncoded.commandDataPayloads.count)
                && clipboardFrame.indices.contains(ClipboardUPipeMessage.commandDataHeaderLength)
                && clipboardFrame[ClipboardUPipeMessage.commandDataHeaderLength] == 0x39,
            detail: "commandID=\(String(format: "0x%02X", clipboardEncoded.commandID)) frames=\(clipboardEncoded.frames.count) header=\(clipboardHeader.map(String.init).joined(separator: ",")) lengthField=\(clipboardLengthField.map(String.init) ?? "none") commandXMLBytes=\(clipboardCommandXMLBytes)"
        ))
        checks.append(SelfTestCheck(
            name: "clipboard.receiveDecode",
            passed: clipboardDecoded?.text == clipboardExpectedText
                && clipboardDecoded?.format == .unicodeText
                && clipboardDecoded?.command == "Cmd_Transfer_Clipboard",
            detail: clipboardDecoded?.summary ?? "not decoded"
        ))
        checks.append(SelfTestCheck(
            name: "clipboard.observe",
            passed: true,
            detail: ClipboardMonitor.currentSummary()
        ))

        print("KMLink Native self-test")
        print("generated: \(ISO8601DateFormatter().string(from: Date()))")
        for check in checks {
            print("\(check.passed ? "PASS" : "FAIL") \(check.name): \(check.detail)")
        }

        let passed = checks.allSatisfy(\.passed)
        print("result: \(passed ? "PASS" : "FAIL")")
        return passed ? 0 : 1
    }
}

private struct SelfTestCheck {
    let name: String
    let passed: Bool
    let detail: String
}
