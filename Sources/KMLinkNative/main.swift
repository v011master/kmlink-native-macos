import AppKit
import Darwin

if CommandLine.arguments.contains("--diagnose") {
    let accessibility = AccessibilityMonitor()
    _ = accessibility.refresh(prompt: false)
    let device = USBDeviceMonitor.currentSnapshot()
    let bridge = OTiBridge()
    bridge.updateDevice(device)

    let report = Diagnostics.render(
        device: device,
        accessibilityTrusted: accessibility.isTrusted,
        clipboardSummary: ClipboardMonitor.currentSummary(),
        inputSummary: "not started in diagnostics mode",
        bridge: bridge
    )
    print(report)
    exit(0)
}

if CommandLine.arguments.contains("--test-hid-release") {
    let transport = OTiHIDTransport()
    let result = transport.sendKeyboardReleaseForDiagnostics()
    print("hid.release.succeeded: \(result.succeeded)")
    print("hid.release.summary: \(result.summary)")
    exit(result.succeeded ? 0 : 1)
}

if CommandLine.arguments.contains("--test-hid-burst") {
    let transport = OTiHIDTransport()
    let result = transport.sendKeyboardReleaseBurstForDiagnostics(count: 10)
    print("hid.burst.succeeded: \(result.succeeded)")
    print("hid.burst.summary: \(result.summary)")
    exit(result.succeeded ? 0 : 1)
}

if CommandLine.arguments.contains("--test-hid-mouse-nudge") {
    let transport = OTiHIDTransport()
    let result = transport.sendMouseNudgeForDiagnostics()
    print("hid.mouseNudge.succeeded: \(result.succeeded)")
    print("hid.mouseNudge.summary: \(result.summary)")
    exit(result.succeeded ? 0 : 1)
}

if CommandLine.arguments.contains("--test-hid-mouse-click") {
    let transport = OTiHIDTransport()
    let result = transport.sendMouseLeftClickForDiagnostics()
    print("hid.mouseClick.succeeded: \(result.succeeded)")
    print("hid.mouseClick.summary: \(result.summary)")
    exit(result.succeeded ? 0 : 1)
}

if CommandLine.arguments.contains("--test-hid-scroll") {
    let transport = OTiHIDTransport()
    let result = transport.sendScrollForDiagnostics()
    print("hid.scroll.succeeded: \(result.succeeded)")
    print("hid.scroll.summary: \(result.summary)")
    exit(result.succeeded ? 0 : 1)
}

if CommandLine.arguments.contains("--test-hid-key-left") {
    let transport = OTiHIDTransport()
    let result = transport.sendKeyboardUsageForDiagnostics(0x50)
    print("hid.keyLeft.succeeded: \(result.succeeded)")
    print("hid.keyLeft.summary: \(result.summary)")
    exit(result.succeeded ? 0 : 1)
}

if CommandLine.arguments.contains("--test-hid-key-escape") {
    let transport = OTiHIDTransport()
    let result = transport.sendKeyboardUsageForDiagnostics(0x29)
    print("hid.keyEscape.succeeded: \(result.succeeded)")
    print("hid.keyEscape.summary: \(result.summary)")
    exit(result.succeeded ? 0 : 1)
}

if CommandLine.arguments.contains("--test-hid-type-text") {
    let index = CommandLine.arguments.firstIndex(of: "--test-hid-type-text")
    let sample = index
        .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
        ?? "KMLINK TEST"
    let transport = OTiHIDTransport()
    let result = transport.sendASCIITextForDiagnostics(sample)
    print("hid.typeText.succeeded: \(result.succeeded)")
    print("hid.typeText.summary: \(result.summary)")
    exit(result.succeeded ? 0 : 1)
}

if CommandLine.arguments.contains("--test-hid-type-text-slow") {
    let index = CommandLine.arguments.firstIndex(of: "--test-hid-type-text-slow")
    let sample = index
        .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
        ?? "kmlink test"
    let transport = OTiHIDTransport()
    let result = transport.sendASCIITextForDiagnostics(sample, delayMilliseconds: 35)
    print("hid.typeTextSlow.succeeded: \(result.succeeded)")
    print("hid.typeTextSlow.summary: \(result.summary)")
    exit(result.succeeded ? 0 : 1)
}

if CommandLine.arguments.contains("--test-data-rx-probe") {
    let result = OTiDataProbe.receiveProbe()
    print("data.rxProbe.succeeded: \(result.succeeded)")
    print("data.rxProbe.summary: \(result.summary)")
    exit(result.succeeded ? 0 : 1)
}

if CommandLine.arguments.contains("--test-clipboard-rx-parse") {
    let result = OTiDataProbe.receiveProbe()
    print("clipboard.rxProbe.succeeded: \(result.succeeded)")
    print("clipboard.rxProbe.summary: \(result.summary)")
    let summary = ClipboardUPipeMessage.summarizeReceivedPacket(result.data)
    for line in summary.lines {
        print(line)
    }
    exit(result.succeeded ? 0 : 1)
}

if CommandLine.arguments.contains("--test-clipboard-rx-xml") {
    let result = OTiDataProbe.receiveProbe()
    print("clipboard.rxXML.succeeded: \(result.succeeded)")
    print("clipboard.rxXML.summary: \(result.summary)")
    if let xml = ClipboardUPipeMessage.xmlString(fromReceivedPacket: result.data) {
        print("clipboard.rxXML.found: true")
        print(xml)
    } else {
        print("clipboard.rxXML.found: false")
    }
    exit(result.succeeded ? 0 : 1)
}

if CommandLine.arguments.contains("--test-clipboard-receive") ||
    CommandLine.arguments.contains("--test-clipboard-receive-apply") {
    let apply = CommandLine.arguments.contains("--test-clipboard-receive-apply")
    let useLegacy = !CommandLine.arguments.contains("--test-clipboard-receive-native")
    if useLegacy {
        let waitSeconds = CommandLine.arguments.firstIndex(of: "--test-clipboard-receive-wait-seconds")
            .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? Double(CommandLine.arguments[$0 + 1]) : nil }
            ?? 18.0
        let expectedText = CommandLine.arguments.firstIndex(of: "--test-clipboard-receive-expected")
            .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
        let result = LegacyClipboardBridge.receiveText(waitSeconds: waitSeconds, expectedText: expectedText) { line in
            print(line)
            fflush(stdout)
        }
        print("clipboard.receive.succeeded: \(result.succeeded)")
        print("clipboard.receive.summary: \(result.summary)")
        if let text = result.text {
            print("clipboard.receive.decoded: true")
            print("clipboard.receive.format: legacyHostText")
            print("clipboard.receive.textChars: \(text.count)")
            print("clipboard.receive.preview: \(String(text.prefix(160)))")
            if apply {
                ClipboardMonitor.setText(text)
                print("clipboard.receive.applied: true")
            } else {
                print("clipboard.receive.applied: false")
            }
        } else {
            print("clipboard.receive.decoded: false")
            print("clipboard.receive.applied: false")
        }
        exit(result.succeeded ? 0 : 1)
    }
    let pollCount = CommandLine.arguments.firstIndex(of: "--test-clipboard-receive-polls")
        .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? Int(CommandLine.arguments[$0 + 1]) : nil }
        ?? (apply ? 12 : 8)
    let pollIntervalMicroseconds = CommandLine.arguments.firstIndex(of: "--test-clipboard-receive-interval-ms")
        .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? Int(CommandLine.arguments[$0 + 1]) : nil }
        .map { max(0, $0) * 1_000 }
        ?? 900_000
    let result = OTiDataProbe.receiveClipboardTextProbe(
        maxPolls: pollCount,
        pollIntervalMicroseconds: useconds_t(pollIntervalMicroseconds)
    )
    print("clipboard.receive.succeeded: \(result.succeeded)")
    print("clipboard.receive.summary: \(result.summary)")
    if let clipboard = result.clipboard {
        print("clipboard.receive.decoded: true")
        print("clipboard.receive.format: \(clipboard.format.rawValue)")
        print("clipboard.receive.textChars: \(clipboard.text.count)")
        print("clipboard.receive.preview: \(String(clipboard.text.prefix(160)))")
        if apply {
            ClipboardMonitor.setText(clipboard.text)
            print("clipboard.receive.applied: true")
        }
    } else {
        print("clipboard.receive.decoded: false")
        print("clipboard.receive.applied: false")
    }
    exit(result.succeeded ? 0 : 1)
}

if CommandLine.arguments.contains("--test-data-tx-dummy") {
    let result = OTiDataProbe.sendDummyProbe()
    print("data.txDummy.succeeded: \(result.succeeded)")
    print("data.txDummy.summary: \(result.summary)")
    exit(result.succeeded ? 0 : 1)
}

if CommandLine.arguments.contains("--test-login-send") {
    let index = CommandLine.arguments.firstIndex(of: "--test-login-send")
    let name = index
        .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
        ?? "TXLIN1"
    let includeCommandTerminator = CommandLine.arguments.contains("--test-login-send-with-terminator")
    let result = OTiDataProbe.sendLoginProbe(name: name, osVersion: 0x07, loginSiteCodePage: 0xA803, includeCommandTerminator: includeCommandTerminator)
    print("login.txProbe.succeeded: \(result.succeeded)")
    print("login.txProbe.summary: \(result.summary)")
    exit(result.succeeded ? 0 : 1)
}

if CommandLine.arguments.contains("--test-raw-command-send") {
    guard let index = CommandLine.arguments.firstIndex(of: "--test-raw-command-send"),
          CommandLine.arguments.indices.contains(index + 1),
          let commandID = UInt8(CommandLine.arguments[index + 1], radix: 16) else {
        print("raw.txProbe.succeeded: false")
        print("raw.txProbe.summary: missing-or-invalid-hex-command-id")
        exit(64)
    }
    let includeCommandTerminator = CommandLine.arguments.contains("--test-raw-command-send-with-terminator")
    let result = OTiDataProbe.sendRawCommandProbe(
        commandID: commandID,
        includeCommandTerminator: includeCommandTerminator
    )
    print("raw.txProbe.succeeded: \(result.succeeded)")
    print("raw.txProbe.summary: \(result.summary)")
    exit(result.succeeded ? 0 : 1)
}

if CommandLine.arguments.contains("--test-login-and-clipboard-send") {
    ClipboardUPipeMessage.resetLegacyCommandSenderState()

    let loginNameIndex = CommandLine.arguments.firstIndex(of: "--test-login-and-clipboard-send")
    let loginName = loginNameIndex
        .flatMap { index -> String? in
            guard CommandLine.arguments.indices.contains(index + 1) else {
                return nil
            }
            let candidate = CommandLine.arguments[index + 1]
            return candidate.hasPrefix("--") ? nil : candidate
        }
        ?? "TXLIN1"
    let textIndex = CommandLine.arguments.firstIndex(of: "--test-clipboard-send")
    let sample = textIndex
        .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
        ?? "KMLink Native combined send probe"

    let format: ClipboardUPipeMessage.Format = CommandLine.arguments.contains("--test-clipboard-send-text-format")
        ? .text
        : .unicodeText
    let contentEnvelope: ClipboardUPipeMessage.ContentEnvelope = format == .text
        ? .rawHex
        : .lengthAndBytes
    let innerXMLMode: ClipboardUPipeMessage.InnerXMLMode = CommandLine.arguments.contains("--test-clipboard-send-raw-inner")
        ? .raw
        : .escaped
    let contentField: ClipboardUPipeMessage.ContentField = CommandLine.arguments.contains("--test-clipboard-send-content-text-field")
        ? .contentText
        : .content
    let unicodePrefix: ClipboardUPipeMessage.UnicodeContentPrefix = CommandLine.arguments.contains("--test-clipboard-send-unicode-bom")
        ? .bom
        : .none
    let unicodeTerminator: ClipboardUPipeMessage.UnicodeTerminator = CommandLine.arguments.contains("--test-clipboard-send-no-unicode-nul")
        ? .none
        : .nul
    let unicodeByteOrder: ClipboardUPipeMessage.UnicodeByteOrder = CommandLine.arguments.contains("--test-clipboard-send-big-unicode")
        ? .big
        : .little
    let commandLengthEndian: ClipboardUPipeMessage.CommandLengthEndian = CommandLine.arguments.contains("--test-clipboard-send-little-length")
        ? .little
        : .big
    let includeCommandTerminator = CommandLine.arguments.contains("--test-clipboard-send-with-terminator")
    let sendShortPayloads = CommandLine.arguments.contains("--test-clipboard-send-short-payload")

    let loginResult = OTiDataProbe.sendLoginProbe(name: loginName, osVersion: 0x07, loginSiteCodePage: 0xA803, includeCommandTerminator: true)
    var handshakeSummaries: [String] = []
    usleep(400_000)
    for _ in 0..<2 {
        let receiveResult = OTiDataProbe.receiveProbe()
        handshakeSummaries.append(receiveResult.summary)
        usleep(250_000)
    }
    let clipboardResult = OTiDataProbe.sendClipboardTextProbe(
        sample,
        format: format,
        innerXMLMode: innerXMLMode,
        contentField: contentField,
        unicodePrefix: unicodePrefix,
        unicodeTerminator: unicodeTerminator,
        unicodeByteOrder: unicodeByteOrder,
        contentEnvelope: contentEnvelope,
        commandLengthEndian: commandLengthEndian,
        includeCommandTerminator: includeCommandTerminator,
        sendShortPayloads: sendShortPayloads
    )

    print("login.txProbe.succeeded: \(loginResult.succeeded)")
    print("login.txProbe.summary: \(loginResult.summary)")
    for (index, summary) in handshakeSummaries.enumerated() {
        print("handshake.rx[\(index + 1)].summary: \(summary)")
    }
    print("clipboard.txProbe.succeeded: \(clipboardResult.succeeded)")
    print("clipboard.txProbe.summary: \(clipboardResult.summary)")
    exit(loginResult.succeeded && clipboardResult.succeeded ? 0 : 1)
}

if CommandLine.arguments.contains("--test-session-trace") {
    ClipboardUPipeMessage.resetLegacyCommandSenderState()

    let loginNameIndex = CommandLine.arguments.firstIndex(of: "--test-session-trace")
    let loginName = loginNameIndex
        .flatMap { index -> String? in
            guard CommandLine.arguments.indices.contains(index + 1) else {
                return nil
            }
            let candidate = CommandLine.arguments[index + 1]
            return candidate.hasPrefix("--") ? nil : candidate
        }
        ?? "TXLIN1"

    let iterations = 8
    let loginResult = OTiDataProbe.sendLoginProbe(name: loginName, osVersion: 0x07, loginSiteCodePage: 0xA803, includeCommandTerminator: true)
    print("session.trace.login.succeeded: \(loginResult.succeeded)")
    print("session.trace.login.summary: \(loginResult.summary)")
    usleep(400_000)

    for index in 0..<iterations {
        let receiveResult = OTiDataProbe.receiveProbe()
        print("session.trace.rx[\(index + 1)].succeeded: \(receiveResult.succeeded)")
        print("session.trace.rx[\(index + 1)].summary: \(receiveResult.summary)")
        let packetSummary = ClipboardUPipeMessage.summarizeReceivedPacket(receiveResult.data)
        for line in packetSummary.lines {
            print("session.trace.rx[\(index + 1)].\(line)")
        }
        if let xml = ClipboardUPipeMessage.xmlString(fromReceivedPacket: receiveResult.data) {
            print("session.trace.rx[\(index + 1)].xml: \(xml)")
        }
        usleep(300_000)
    }

    exit(loginResult.succeeded ? 0 : 1)
}

if CommandLine.arguments.contains("--test-session-init-and-clipboard-send") {
    ClipboardUPipeMessage.resetLegacyCommandSenderState()
    if CommandLine.arguments.contains("--test-legacy-header-mirrored-packet-serial") {
        ClipboardUPipeMessage.setLegacyHeaderMode(.mirroredPacketSerial)
    }

    let textIndex = CommandLine.arguments.firstIndex(of: "--test-clipboard-send")
    let sample = textIndex
        .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
        ?? "KMLink Native init session send probe"

    let format: ClipboardUPipeMessage.Format = CommandLine.arguments.contains("--test-clipboard-send-text-format")
        ? .text
        : .unicodeText
    let contentEnvelope: ClipboardUPipeMessage.ContentEnvelope = format == .text
        ? .rawHex
        : .lengthAndBytes
    let innerXMLMode: ClipboardUPipeMessage.InnerXMLMode = CommandLine.arguments.contains("--test-clipboard-send-raw-inner")
        ? .raw
        : .escaped
    let contentField: ClipboardUPipeMessage.ContentField = CommandLine.arguments.contains("--test-clipboard-send-content-text-field")
        ? .contentText
        : .content
    let unicodePrefix: ClipboardUPipeMessage.UnicodeContentPrefix = CommandLine.arguments.contains("--test-clipboard-send-unicode-bom")
        ? .bom
        : .none
    let unicodeTerminator: ClipboardUPipeMessage.UnicodeTerminator = CommandLine.arguments.contains("--test-clipboard-send-no-unicode-nul")
        ? .none
        : .nul
    let unicodeByteOrder: ClipboardUPipeMessage.UnicodeByteOrder = CommandLine.arguments.contains("--test-clipboard-send-big-unicode")
        ? .big
        : .little
    let commandLengthEndian: ClipboardUPipeMessage.CommandLengthEndian = CommandLine.arguments.contains("--test-clipboard-send-little-length")
        ? .little
        : .big
    let includeCommandTerminator = CommandLine.arguments.contains("--test-clipboard-send-with-terminator")

    let loginResult = OTiDataProbe.sendLoginProbe(name: "TXLIN1", osVersion: 0x07, loginSiteCodePage: 0xA803, includeCommandTerminator: true)
    print("session.init.login.succeeded: \(loginResult.succeeded)")
    print("session.init.login.summary: \(loginResult.summary)")

    usleep(300_000)
    let dynamicAD = LegacySessionPreset.domainFoldersCommand()
    let dynamicA4 = LegacySessionPreset.localDrivesCommand()
    let initCommands: [(UInt8, [UInt8])] = [
        (LegacySessionPreset.initialA1.first ?? 0xA1, Array(LegacySessionPreset.initialA1.dropFirst())),
        (dynamicAD.first ?? 0xAD, Array(dynamicAD.dropFirst())),
        (dynamicA4.first ?? 0xA4, Array(dynamicA4.dropFirst()))
    ]
    for (commandID, payload) in initCommands {
        let rawResult = OTiDataProbe.sendRawCommandProbe(commandID: commandID, payload: payload)
        print("session.init.raw.\(String(format: "%02X", commandID)).succeeded: \(rawResult.succeeded)")
        print("session.init.raw.\(String(format: "%02X", commandID)).summary: \(rawResult.summary)")
        usleep(250_000)
    }

    var sentDirectoryReplies = false
    for index in 0..<4 {
        let receiveResult = OTiDataProbe.receiveProbe()
        let packetSummary = ClipboardUPipeMessage.summarizeReceivedPacket(receiveResult.data)
        print("session.init.rx[\(index + 1)].summary: \(receiveResult.summary)")
        print("session.init.rx[\(index + 1)].command: \(packetSummary.command ?? "none")")
        print("session.init.rx[\(index + 1)].appCommandID: \(packetSummary.appCommandID ?? "none")")
        if packetSummary.appCommandID == "0x04" {
            let a1 = OTiDataProbe.sendRawCommandProbe(
                commandID: LegacySessionPreset.postDirectoryA1.first ?? 0xA1,
                payload: Array(LegacySessionPreset.postDirectoryA1.dropFirst())
            )
            let a2 = OTiDataProbe.sendRawCommandProbe(
                commandID: LegacySessionPreset.a2.first ?? 0xA2,
                payload: Array(LegacySessionPreset.a2.dropFirst())
            )
            print("session.init.reply.A1.summary: \(a1.summary)")
            print("session.init.reply.A2.summary: \(a2.summary)")
            sentDirectoryReplies = true
        }
        usleep(250_000)
    }

    if !sentDirectoryReplies {
        let a1 = OTiDataProbe.sendRawCommandProbe(
            commandID: LegacySessionPreset.postDirectoryA1.first ?? 0xA1,
            payload: Array(LegacySessionPreset.postDirectoryA1.dropFirst())
        )
        let a2 = OTiDataProbe.sendRawCommandProbe(
            commandID: LegacySessionPreset.a2.first ?? 0xA2,
            payload: Array(LegacySessionPreset.a2.dropFirst())
        )
        print("session.init.reply.A1.fallback.summary: \(a1.summary)")
        print("session.init.reply.A2.fallback.summary: \(a2.summary)")
    }

    let clipboardResult = OTiDataProbe.sendClipboardTextProbe(
        sample,
        format: format,
        innerXMLMode: innerXMLMode,
        contentField: contentField,
        unicodePrefix: unicodePrefix,
        unicodeTerminator: unicodeTerminator,
        unicodeByteOrder: unicodeByteOrder,
        contentEnvelope: contentEnvelope,
        commandLengthEndian: commandLengthEndian,
        includeCommandTerminator: includeCommandTerminator
    )
    print("session.init.clipboard.succeeded: \(clipboardResult.succeeded)")
    print("session.init.clipboard.summary: \(clipboardResult.summary)")
    let postReceiveCount = CommandLine.arguments.contains("--test-session-post-rx-10") ? 10 : 4
    for index in 0..<postReceiveCount {
        let receiveResult = OTiDataProbe.receiveProbe()
        let packetSummary = ClipboardUPipeMessage.summarizeReceivedPacket(receiveResult.data)
        print("session.init.postRx[\(index + 1)].summary: \(receiveResult.summary)")
        print("session.init.postRx[\(index + 1)].command: \(packetSummary.command ?? "none")")
        print("session.init.postRx[\(index + 1)].appCommandID: \(packetSummary.appCommandID ?? "none")")
        if let xml = ClipboardUPipeMessage.xmlString(fromReceivedPacket: receiveResult.data) {
            print("session.init.postRx[\(index + 1)].xml: \(xml)")
        }
        usleep(200_000)
    }
    exit(loginResult.succeeded && clipboardResult.succeeded ? 0 : 1)
}

if CommandLine.arguments.contains("--test-clipboard-send") {
    let index = CommandLine.arguments.firstIndex(of: "--test-clipboard-send")
    let sample = index
        .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
        ?? ClipboardMonitor.currentText()
        ?? "KMLink Native clipboard send probe"
    let format: ClipboardUPipeMessage.Format = CommandLine.arguments.contains("--test-clipboard-send-text-format")
        ? .text
        : .unicodeText
    let contentEnvelope: ClipboardUPipeMessage.ContentEnvelope = format == .text
        ? .rawHex
        : .lengthAndBytes
    let innerXMLMode: ClipboardUPipeMessage.InnerXMLMode = CommandLine.arguments.contains("--test-clipboard-send-raw-inner")
        ? .raw
        : .escaped
    let contentField: ClipboardUPipeMessage.ContentField = CommandLine.arguments.contains("--test-clipboard-send-content-text-field")
        ? .contentText
        : .content
    let unicodePrefix: ClipboardUPipeMessage.UnicodeContentPrefix = CommandLine.arguments.contains("--test-clipboard-send-unicode-bom")
        ? .bom
        : .none
    let unicodeTerminator: ClipboardUPipeMessage.UnicodeTerminator = CommandLine.arguments.contains("--test-clipboard-send-no-unicode-nul")
        ? .none
        : .nul
    let unicodeByteOrder: ClipboardUPipeMessage.UnicodeByteOrder = CommandLine.arguments.contains("--test-clipboard-send-big-unicode")
        ? .big
        : .little
    let commandLengthEndian: ClipboardUPipeMessage.CommandLengthEndian = CommandLine.arguments.contains("--test-clipboard-send-little-length")
        ? .little
        : .big
    let includeCommandTerminator = CommandLine.arguments.contains("--test-clipboard-send-with-terminator")
    let sendShortPayloads = CommandLine.arguments.contains("--test-clipboard-send-short-payload")
    let result = OTiDataProbe.sendClipboardTextProbe(
        sample,
        format: format,
        innerXMLMode: innerXMLMode,
        contentField: contentField,
        unicodePrefix: unicodePrefix,
        unicodeTerminator: unicodeTerminator,
        unicodeByteOrder: unicodeByteOrder,
        contentEnvelope: contentEnvelope,
        commandLengthEndian: commandLengthEndian,
        includeCommandTerminator: includeCommandTerminator,
        sendShortPayloads: sendShortPayloads
    )
    print("clipboard.txProbe.succeeded: \(result.succeeded)")
    print("clipboard.txProbe.summary: \(result.summary)")
    exit(result.succeeded ? 0 : 1)
}

if CommandLine.arguments.contains("--test-clipboard-send-initialized") {
    let index = CommandLine.arguments.firstIndex(of: "--test-clipboard-send-initialized")
    let sample = index
        .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
        ?? ClipboardMonitor.currentText()
        ?? "KMLink Native initialized clipboard send probe"
    let result = OTiDataProbe.sendInitializedClipboardTextProbe(
        sample,
        sendSwitchToRemoteNotify: CommandLine.arguments.contains("--test-send-switch-notify"),
        includeClipboardCommandTerminator: !CommandLine.arguments.contains("--test-no-clipboard-terminator")
    )
    print("clipboard.initTxProbe.succeeded: \(result.succeeded)")
    print("clipboard.initTxProbe.summary: \(result.summary)")
    exit(result.succeeded ? 0 : 1)
}

if CommandLine.arguments.contains("--test-clipboard-send-legacy") {
    let index = CommandLine.arguments.firstIndex(of: "--test-clipboard-send-legacy")
    let sample = index
        .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
        ?? "KMLink Native legacy clipboard bridge probe"
    let result = LegacyClipboardBridge.sendText(sample)
    print("clipboard.legacyTx.succeeded: \(result.succeeded)")
    print("clipboard.legacyTx.summary: \(result.summary)")
    exit(result.succeeded ? 0 : 1)
}

if CommandLine.arguments.contains("--test-legacy-remote-session") {
    let result = LegacyClipboardBridge.probeRemoteSession()
    print("legacy.session.initialized: \(result.initialized)")
    print("legacy.session.tapEnabled: \(result.tapEnabled)")
    print("legacy.session.clipboardEnabled: \(result.clipboardEnabled)")
    print("legacy.session.connected: \(result.connected)")
    print("legacy.session.remoteAppOff: \(result.remoteAppOff)")
    print("legacy.session.logPath: \(result.logPath ?? "none")")
    print("legacy.session.summary: \(result.summary)")
    exit(result.connected ? 0 : 1)
}

if CommandLine.arguments.contains("--test-clipboard-encode") {
    let sample = "KMLink Native clipboard probe\nLine two"
    let encoded = ClipboardUPipeMessage.encodeText(sample)
    let firstFrame = encoded.frames.first ?? []
    let prefix = firstFrame.prefix(32).map { String(format: "%02X", $0) }.joined()
    print("clipboard.encode.succeeded: \(ClipboardUPipeMessage.validateFrames(encoded.frames))")
    print("clipboard.encode.format: \(encoded.format.rawValue)")
    print("clipboard.encode.xmlBytes: \(encoded.bytes.count)")
    print("clipboard.encode.frames: \(encoded.frames.count)")
    print("clipboard.encode.frameBytes: \(firstFrame.count)")
    print("clipboard.encode.prefix: \(prefix)")
    exit(ClipboardUPipeMessage.validateFrames(encoded.frames) ? 0 : 1)
}

if CommandLine.arguments.contains("--test-clipboard-gobridge-encode") {
    let sample = "KMLink Native clipboard probe\nLine two"
    let encoded = ClipboardUPipeMessage.encodeTextGoBridgeCommand(sample)
    let firstFrame = encoded.frames.first ?? []
    let firstPayload = encoded.commandDataPayloads.first ?? []
    let headerValues = ClipboardUPipeMessage.commandDataHeaderValues(from: firstFrame) ?? []
    let prefix = firstFrame.prefix(32).map { String(format: "%02X", $0) }.joined()
    let commandPrefix = encoded.commandBytes.prefix(16).map { String(format: "%02X", $0) }.joined()
    let payloadPrefix = firstPayload.prefix(32).map { String(format: "%02X", $0) }.joined()
    let lengthField = ClipboardUPipeMessage.commandXMLLength(from: encoded.commandBytes)
    let commandXMLBytes = encoded.commandBytes.count >= 5 ? encoded.commandBytes.count - 5 : 0
    let succeeded = ClipboardUPipeMessage.validateFrames(encoded.frames)
        && encoded.commandID == 0x39
        && lengthField == UInt32(commandXMLBytes)
        && headerValues.count == 5
        && headerValues[2] == 0
        && headerValues[3] == UInt32(encoded.commandDataPayloads.count)
        && headerValues[4] == UInt32(min(encoded.commandBytes.count, ClipboardUPipeMessage.maxCommandDataChunkLength))
        && firstFrame.count > ClipboardUPipeMessage.commandDataHeaderLength
        && firstFrame[ClipboardUPipeMessage.commandDataHeaderLength] == encoded.commandID
    print("clipboard.gobridgeEncode.succeeded: \(succeeded)")
    print("clipboard.gobridgeEncode.format: \(encoded.format.rawValue)")
    print("clipboard.gobridgeEncode.commandID: \(String(format: "0x%02X", encoded.commandID))")
    print("clipboard.gobridgeEncode.xmlBytes: \(encoded.xml.utf8.count)")
    print("clipboard.gobridgeEncode.commandXMLBytes: \(commandXMLBytes)")
    print("clipboard.gobridgeEncode.commandBytes: \(encoded.commandBytes.count)")
    print("clipboard.gobridgeEncode.lengthField: \(lengthField.map(String.init) ?? "none")")
    print("clipboard.gobridgeEncode.commandDataPayloads: \(encoded.commandDataPayloads.count)")
    print("clipboard.gobridgeEncode.commandDataHeaderLE: \(headerValues.map { String(format: "0x%08X/%u", $0, $0) }.joined(separator: ","))")
    print("clipboard.gobridgeEncode.frames: \(encoded.frames.count)")
    print("clipboard.gobridgeEncode.frameBytes: \(firstFrame.count)")
    print("clipboard.gobridgeEncode.commandPrefix: \(commandPrefix)")
    print("clipboard.gobridgeEncode.payloadPrefix: \(payloadPrefix)")
    print("clipboard.gobridgeEncode.framePrefix: \(prefix)")
    exit(succeeded ? 0 : 1)
}

if CommandLine.arguments.contains("--test-clipboard-receive-decode") {
    let sample = "KMLink Native clipboard receive decode\nLine two"
    let expected = "KMLink Native clipboard receive decode\r\nLine two"
    let encoded = ClipboardUPipeMessage.encodeTextGoBridgeCommand(sample)
    let decoded = encoded.frames.first.flatMap(ClipboardUPipeMessage.clipboardText(fromReceivedPacket:))
    let succeeded = decoded?.text == expected
        && decoded?.format == .unicodeText
        && decoded?.command == "Cmd_Transfer_Clipboard"
    print("clipboard.receiveDecode.succeeded: \(succeeded)")
    print("clipboard.receiveDecode.decoded: \(decoded != nil)")
    print("clipboard.receiveDecode.summary: \(decoded?.summary ?? "none")")
    print("clipboard.receiveDecode.preview: \(decoded.map { String($0.text.prefix(160)) } ?? "none")")
    exit(succeeded ? 0 : 1)
}

if CommandLine.arguments.contains("--self-test") {
    exit(SelfTest.run())
}

let app = NSApplication.shared
let delegate = AppDelegate()

app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
