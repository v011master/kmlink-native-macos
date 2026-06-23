import Foundation
import IOKit
import KMLinkNativeCSCSI

struct OTiDataProbeResult {
    let succeeded: Bool
    let summary: String
    let data: [UInt8]
}

struct OTiClipboardReceiveResult {
    let succeeded: Bool
    let summary: String
    let clipboard: ClipboardUPipeMessage.ReceivedClipboard?
    let transport: OTiDataProbeResult
}

enum OTiDataProbe {
    private struct ClipboardSendAttempt {
        let label: String
        let delayMicroseconds: useconds_t
        let format: ClipboardUPipeMessage.Format
        let innerXMLMode: ClipboardUPipeMessage.InnerXMLMode
        let contentEnvelope: ClipboardUPipeMessage.ContentEnvelope
        let includeCommandTerminator: Bool
    }

    static func sendInitializedClipboardTextProbe(
        _ text: String,
        sendSwitchToRemoteNotify: Bool = false,
        includeClipboardCommandTerminator: Bool = true
    ) -> OTiDataProbeResult {
        ClipboardUPipeMessage.resetLegacyCommandSenderState()
        ClipboardUPipeMessage.setLegacyHeaderMode(.mirroredPacketSerial)

        let lock = SCSITransportLock()
        guard lock.acquire() else {
            return OTiDataProbeResult(succeeded: false, summary: "sessionClipboardTx transport-busy", data: [])
        }
        defer { lock.release() }

        guard let usbService = findUSBDevice() else {
            return OTiDataProbeResult(succeeded: false, summary: "sessionClipboardTx no-usb-device", data: [])
        }
        defer { IOObjectRelease(usbService) }

        let preparation = SCSIMediaPreparer.unmountMediaIfPresent(from: usbService)
        guard let service = firstCompactDiscService(from: usbService) else {
            return OTiDataProbeResult(succeeded: false, summary: "sessionClipboardTx no-io-service; \(preparation)", data: [])
        }
        defer { IOObjectRelease(service) }

        var openRaw = KMLinkSCSICommandResult()
        guard let session = KMLinkSCSISessionOpen(service, &openRaw) else {
            return OTiDataProbeResult(
                succeeded: false,
                summary: "sessionClipboardTx session-open failed; \(preparation) result=\(openRaw.result) plugin=\(hex(openRaw.pluginResult)) exclusive=\(hex(openRaw.exclusiveResult))",
                data: []
            )
        }
        defer { KMLinkSCSISessionClose(session) }

        var summaries: [String] = []
        if !preparation.isEmpty {
            summaries.append(preparation)
        }

        let loginEncoded = ClipboardUPipeMessage.encodeLoginGoBridgeCommand(
            name: "TXLIN1",
            osVersion: 0x07,
            loginSiteCodePage: 0xA803,
            includeCommandTerminator: true
        )
        let loginFrames = ClipboardUPipeMessage.dataOutFrames(fromCommandDataPayloads: loginEncoded.commandDataPayloads)
        let loginResult = sendFramesOnSession(
            session,
            name: "loginTx",
            frames: loginFrames,
            commandBytes: loginEncoded.commandBytes,
            successLabel: "loginTx sent commandID=\(String(format: "0x%02X", loginEncoded.commandID)) name=TXLIN1 osVersion=0x07 siteCodePage=0xA803 commandBytes=\(loginEncoded.commandBytes.count) commandPrefix=\(loginEncoded.commandBytes.prefix(16).map { String(format: "%02X", $0) }.joined()) frames=\(loginFrames.count) frameBytes=\(loginFrames.first?.count ?? 0)"
        )
        summaries.append(loginResult.summary)
        guard loginResult.succeeded else {
            return OTiDataProbeResult(succeeded: false, summary: "sessionClipboardTx login failed; \(summaries.joined(separator: " | "))", data: [])
        }
        usleep(300_000)

        let initCommands: [[UInt8]] = [
            LegacySessionPreset.initialA1,
            LegacySessionPreset.domainFoldersCommand(),
            LegacySessionPreset.localDrivesCommand()
        ]
        for command in initCommands where !command.isEmpty {
            let encoded = ClipboardUPipeMessage.encodeRawCommand(
                commandID: command[0],
                payload: Array(command.dropFirst()),
                includeCommandTerminator: false
            )
            let frames = ClipboardUPipeMessage.dataOutFrames(fromCommandDataPayloads: encoded.commandDataPayloads)
            let rawResult = sendFramesOnSession(
                session,
                name: "rawTx",
                frames: frames,
                commandBytes: encoded.commandBytes,
                successLabel: "rawTx sent commandID=\(String(format: "0x%02X", command[0])) commandBytes=\(encoded.commandBytes.count) commandPrefix=\(encoded.commandBytes.prefix(16).map { String(format: "%02X", $0) }.joined()) frames=\(frames.count) frameBytes=\(frames.first?.count ?? 0)"
            )
            summaries.append(rawResult.summary)
            guard rawResult.succeeded else {
                return OTiDataProbeResult(succeeded: false, summary: "sessionClipboardTx init failed; \(summaries.joined(separator: " | "))", data: [])
            }
            usleep(250_000)
        }

        for _ in 0..<4 {
            let receiveResult = runDataCommandOnSession(
                session,
                name: "rxProbe",
                cdb: dataCDB(byte1: 0x28, byte2: 0x64),
                payload: nil,
                receiveLength: 0x10000,
                direction: 2
            )
            summaries.append(receiveResult.summary)
            usleep(200_000)
        }

        for command in [LegacySessionPreset.postDirectoryA1, LegacySessionPreset.a2] where !command.isEmpty {
            let encoded = ClipboardUPipeMessage.encodeRawCommand(
                commandID: command[0],
                payload: Array(command.dropFirst()),
                includeCommandTerminator: false
            )
            let frames = ClipboardUPipeMessage.dataOutFrames(fromCommandDataPayloads: encoded.commandDataPayloads)
            let rawResult = sendFramesOnSession(
                session,
                name: "rawTx",
                frames: frames,
                commandBytes: encoded.commandBytes,
                successLabel: "rawTx sent commandID=\(String(format: "0x%02X", command[0])) commandBytes=\(encoded.commandBytes.count) commandPrefix=\(encoded.commandBytes.prefix(16).map { String(format: "%02X", $0) }.joined()) frames=\(frames.count) frameBytes=\(frames.first?.count ?? 0)"
            )
            summaries.append(rawResult.summary)
            guard rawResult.succeeded else {
                return OTiDataProbeResult(succeeded: false, summary: "sessionClipboardTx post-init failed; \(summaries.joined(separator: " | "))", data: [])
            }
            usleep(250_000)
        }

        if sendSwitchToRemoteNotify {
            let encoded = ClipboardUPipeMessage.encodeXMLGoBridgeCommand(
                LegacySessionPreset.notifySwitchToRemoteXML,
                includeCommandTerminator: true
            )
            let frames = ClipboardUPipeMessage.dataOutFrames(fromCommandDataPayloads: encoded.commandDataPayloads)
            let switchNotify = sendFramesOnSession(
                session,
                name: "xmlTx",
                frames: frames,
                commandBytes: encoded.commandBytes,
                successLabel: "xmlTx sent commandID=\(String(format: "0x%02X", encoded.commandID)) commandBytes=\(encoded.commandBytes.count) commandPrefix=\(encoded.commandBytes.prefix(16).map { String(format: "%02X", $0) }.joined()) frames=\(frames.count) frameBytes=\(frames.first?.count ?? 0)"
            )
            summaries.append(switchNotify.summary)
            guard switchNotify.succeeded else {
                return OTiDataProbeResult(succeeded: false, summary: "sessionClipboardTx switchNotify failed; \(summaries.joined(separator: " | "))", data: [])
            }
            usleep(250_000)
        }

        let attempts: [ClipboardSendAttempt] = [
            ClipboardSendAttempt(
                label: "legacyTextCompat",
                delayMicroseconds: 4_200_000,
                format: .text,
                innerXMLMode: .raw,
                contentEnvelope: .rawHex,
                includeCommandTerminator: includeClipboardCommandTerminator
            )
        ]

        var clipboardResult = OTiDataProbeResult(succeeded: false, summary: "clipboardTx not-started", data: [])
        for attempt in attempts {
            usleep(attempt.delayMicroseconds)
            let encoded = ClipboardUPipeMessage.encodeTextGoBridgeCommand(
                text,
                format: attempt.format,
                innerXMLMode: attempt.innerXMLMode,
                contentField: .content,
                unicodePrefix: .none,
                unicodeTerminator: .nul,
                unicodeByteOrder: .little,
                contentEnvelope: attempt.contentEnvelope,
                commandLengthEndian: .big,
                includeCommandTerminator: attempt.includeCommandTerminator
            )
            let frames = ClipboardUPipeMessage.dataOutFrames(fromCommandDataPayloads: encoded.commandDataPayloads)
            clipboardResult = sendFramesOnSession(
                session,
                name: "clipboardTx",
                frames: frames,
                commandBytes: encoded.commandBytes,
                successLabel: "clipboardTx sent format=\(encoded.format.rawValue) chars=\(text.count) xmlBytes=\(encoded.xml.utf8.count) commandBytes=\(encoded.commandBytes.count) frames=\(frames.count) frameBytes=\(frames.first?.count ?? 0)"
            )
            summaries.append("clipboardAttempt[\(attempt.label)] \(clipboardResult.summary)")
        }

        var postReceiveSummaries: [String] = []
        var postReceiveData: [UInt8] = []
        for index in 0..<6 {
            let receiveResult = runDataCommandOnSession(
                session,
                name: "rxProbe",
                cdb: dataCDB(byte1: 0x28, byte2: 0x64),
                payload: nil,
                receiveLength: 0x10000,
                direction: 2
            )
            if postReceiveData.isEmpty, !receiveResult.data.isEmpty {
                postReceiveData = receiveResult.data
            }
            let packetSummary = ClipboardUPipeMessage.summarizeReceivedPacket(receiveResult.data)
            let command = packetSummary.command ?? "none"
            let appCommandID = packetSummary.appCommandID ?? "none"
            postReceiveSummaries.append("postRx[\(index + 1)] \(receiveResult.summary) command=\(command) appCommandID=\(appCommandID)")
            usleep(200_000)
        }
        summaries.append(contentsOf: postReceiveSummaries)
        return OTiDataProbeResult(
            succeeded: clipboardResult.succeeded,
            summary: "sessionClipboardTx \(clipboardResult.succeeded ? "sent" : "failed"); \(summaries.joined(separator: " | "))",
            data: postReceiveData.isEmpty ? clipboardResult.data : postReceiveData
        )
    }

    static func sendDummyProbe() -> OTiDataProbeResult {
        let packet = [UInt8](repeating: 0, count: 0x10000)
        return runDataCommand(
            name: "txDummy",
            cdb: dataCDB(byte1: 0x2A, byte2: 0xFF),
            payload: packet,
            receiveLength: 0,
            direction: 1
        )
    }

    static func sendClipboardTextProbe(
        _ text: String,
        format: ClipboardUPipeMessage.Format = .unicodeText,
        innerXMLMode: ClipboardUPipeMessage.InnerXMLMode = .escaped,
        contentField: ClipboardUPipeMessage.ContentField = .content,
        unicodePrefix: ClipboardUPipeMessage.UnicodeContentPrefix = .none,
        unicodeTerminator: ClipboardUPipeMessage.UnicodeTerminator = .nul,
        unicodeByteOrder: ClipboardUPipeMessage.UnicodeByteOrder = .little,
        contentEnvelope: ClipboardUPipeMessage.ContentEnvelope = .lengthAndBytes,
        commandLengthEndian: ClipboardUPipeMessage.CommandLengthEndian = .big,
        includeCommandTerminator: Bool = false,
        sendShortPayloads: Bool = false
    ) -> OTiDataProbeResult {
        let encoded = ClipboardUPipeMessage.encodeTextGoBridgeCommand(
            text,
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
        let frames = sendShortPayloads
            ? encoded.commandDataPayloads.map { payload in
                var shortPayload = [UInt8](repeating: 0, count: ClipboardUPipeMessage.packetPayloadLength)
                shortPayload.replaceSubrange(0..<min(payload.count, shortPayload.count), with: payload.prefix(shortPayload.count))
                return shortPayload
            }
            : ClipboardUPipeMessage.dataOutFrames(fromCommandDataPayloads: encoded.commandDataPayloads)
        var summaries: [String] = []

        for (index, frame) in frames.enumerated() {
            let result = runDataCommand(
                name: "clipboardTx[\(index + 1)/\(frames.count)]",
                cdb: dataCDB(byte1: 0x2A, byte2: 0xFF),
                payload: frame,
                receiveLength: 0,
                direction: 1
            )
            summaries.append(result.summary)

            guard result.succeeded else {
                return OTiDataProbeResult(
                    succeeded: false,
                    summary: "clipboardTx failed format=\(encoded.format.rawValue) xmlBytes=\(encoded.xml.utf8.count) commandBytes=\(encoded.commandBytes.count) frames=\(frames.count); \(summaries.joined(separator: " | "))",
                    data: []
                )
            }
        }

        return OTiDataProbeResult(
            succeeded: true,
            summary: "clipboardTx sent format=\(encoded.format.rawValue) chars=\(text.count) xmlBytes=\(encoded.xml.utf8.count) commandBytes=\(encoded.commandBytes.count) frames=\(frames.count) frameBytes=\(frames.first?.count ?? 0); \(summaries.joined(separator: " | "))",
            data: []
        )
    }

    static func sendLoginProbe(
        name: String = "TXLIN1",
        osVersion: UInt8 = 0x07,
        loginSiteCodePage: UInt16 = 0xA803,
        includeCommandTerminator: Bool = false
    ) -> OTiDataProbeResult {
        let encoded = ClipboardUPipeMessage.encodeLoginGoBridgeCommand(
            name: name,
            osVersion: osVersion,
            loginSiteCodePage: loginSiteCodePage,
            includeCommandTerminator: includeCommandTerminator
        )
        let frames = ClipboardUPipeMessage.dataOutFrames(fromCommandDataPayloads: encoded.commandDataPayloads)
        var summaries: [String] = []

        for (index, frame) in frames.enumerated() {
            let result = runDataCommand(
                name: "loginTx[\(index + 1)/\(frames.count)]",
                cdb: dataCDB(byte1: 0x2A, byte2: 0xFF),
                payload: frame,
                receiveLength: 0,
                direction: 1
            )
            summaries.append(result.summary)

            guard result.succeeded else {
                return OTiDataProbeResult(
                    succeeded: false,
                    summary: "loginTx failed commandID=\(String(format: "0x%02X", encoded.commandID)) commandBytes=\(encoded.commandBytes.count) frames=\(frames.count); \(summaries.joined(separator: " | "))",
                    data: []
                )
            }
        }

        let commandPrefix = encoded.commandBytes.prefix(16).map { String(format: "%02X", $0) }.joined()
        return OTiDataProbeResult(
            succeeded: true,
            summary: "loginTx sent commandID=\(String(format: "0x%02X", encoded.commandID)) name=\(name) osVersion=\(String(format: "0x%02X", osVersion)) siteCodePage=\(String(format: "0x%04X", loginSiteCodePage)) commandBytes=\(encoded.commandBytes.count) commandPrefix=\(commandPrefix) frames=\(frames.count) frameBytes=\(frames.first?.count ?? 0); \(summaries.joined(separator: " | "))",
            data: []
        )
    }

    static func sendRawCommandProbe(
        commandID: UInt8,
        payload: [UInt8] = [],
        includeCommandTerminator: Bool = false
    ) -> OTiDataProbeResult {
        let encoded = ClipboardUPipeMessage.encodeRawCommand(
            commandID: commandID,
            payload: payload,
            includeCommandTerminator: includeCommandTerminator
        )
        let frames = ClipboardUPipeMessage.dataOutFrames(fromCommandDataPayloads: encoded.commandDataPayloads)
        var summaries: [String] = []

        for (index, frame) in frames.enumerated() {
            let result = runDataCommand(
                name: "rawTx[\(index + 1)/\(frames.count)]",
                cdb: dataCDB(byte1: 0x2A, byte2: 0xFF),
                payload: frame,
                receiveLength: 0,
                direction: 1
            )
            summaries.append(result.summary)

            guard result.succeeded else {
                return OTiDataProbeResult(
                    succeeded: false,
                    summary: "rawTx failed commandID=\(String(format: "0x%02X", commandID)) commandBytes=\(encoded.commandBytes.count) frames=\(frames.count); \(summaries.joined(separator: " | "))",
                    data: []
                )
            }
        }

        let commandPrefix = encoded.commandBytes.prefix(16).map { String(format: "%02X", $0) }.joined()
        return OTiDataProbeResult(
            succeeded: true,
            summary: "rawTx sent commandID=\(String(format: "0x%02X", commandID)) commandBytes=\(encoded.commandBytes.count) commandPrefix=\(commandPrefix) frames=\(frames.count) frameBytes=\(frames.first?.count ?? 0); \(summaries.joined(separator: " | "))",
            data: []
        )
    }

    static func receiveProbe() -> OTiDataProbeResult {
        runDataCommand(
            name: "rxProbe",
            cdb: dataCDB(byte1: 0x28, byte2: 0x64),
            payload: nil,
            receiveLength: 0x10000,
            direction: 2
        )
    }

    static func receiveClipboardTextProbe(
        maxPolls: Int = 1,
        pollIntervalMicroseconds: useconds_t = 0
    ) -> OTiClipboardReceiveResult {
        let pollCount = max(1, maxPolls)
        let lock = SCSITransportLock()
        guard lock.acquire() else {
            let transport = OTiDataProbeResult(succeeded: false, summary: "clipboardRx transport-busy", data: [])
            return OTiClipboardReceiveResult(
                succeeded: false,
                summary: "clipboardRx transport-busy",
                clipboard: nil,
                transport: transport
            )
        }
        defer { lock.release() }

        guard let usbService = findUSBDevice() else {
            let transport = OTiDataProbeResult(succeeded: false, summary: "clipboardRx no-usb-device", data: [])
            return OTiClipboardReceiveResult(
                succeeded: false,
                summary: "clipboardRx no-usb-device",
                clipboard: nil,
                transport: transport
            )
        }
        defer { IOObjectRelease(usbService) }

        let preparation = SCSIMediaPreparer.unmountMediaIfPresent(from: usbService)

        var session: OpaquePointer?
        var openRaw = KMLinkSCSICommandResult()
        var sessionOpenNotes: [String] = preparation.isEmpty ? [] : [preparation]
        for attempt in 0..<4 {
            if attempt > 0 {
                usleep(400_000)
            }

            guard let currentUSBService = findUSBDevice() else {
                sessionOpenNotes.append("retry\(attempt)=no-usb-device")
                continue
            }

            let retryPreparation: String
            if attempt == 0 {
                retryPreparation = preparation
            } else {
                retryPreparation = SCSIMediaPreparer.unmountMediaIfPresent(from: currentUSBService)
                if !retryPreparation.isEmpty {
                    sessionOpenNotes.append("retry\(attempt)=\(retryPreparation)")
                }
            }

            guard let currentService = firstCompactDiscService(from: currentUSBService) else {
                IOObjectRelease(currentUSBService)
                sessionOpenNotes.append("retry\(attempt)=no-io-service")
                continue
            }

            session = KMLinkSCSISessionOpen(currentService, &openRaw)
            IOObjectRelease(currentService)
            IOObjectRelease(currentUSBService)

            if session != nil {
                break
            }

            sessionOpenNotes.append("retry\(attempt)=session-open result=\(openRaw.result) plugin=\(hex(openRaw.pluginResult)) exclusive=\(hex(openRaw.exclusiveResult))")
        }

        guard let session else {
            let notes = sessionOpenNotes.joined(separator: " | ")
            let summary = "clipboardRx session-open failed; \(notes)"
            let transport = OTiDataProbeResult(succeeded: false, summary: summary, data: [])
            return OTiClipboardReceiveResult(
                succeeded: false,
                summary: summary,
                clipboard: nil,
                transport: transport
            )
        }
        defer { KMLinkSCSISessionClose(session) }

        var attempts: [String] = []
        var lastTransport = OTiDataProbeResult(succeeded: false, summary: "clipboardRx not-started", data: [])
        var sawAnyTransportSuccess = false

        for index in 0..<pollCount {
            let transport = runDataCommandOnSession(
                session,
                name: "rxProbe",
                cdb: dataCDB(byte1: 0x28, byte2: 0x64),
                payload: nil,
                receiveLength: 0x10000,
                direction: 2
            )
            lastTransport = transport
            sawAnyTransportSuccess = sawAnyTransportSuccess || transport.succeeded

            if let clipboard = ClipboardUPipeMessage.clipboardText(fromReceivedPacket: transport.data) {
                let summaryPrefix = pollCount > 1 ? "clipboardRx decoded after \(index + 1)/\(pollCount) polls" : "clipboardRx decoded"
                return OTiClipboardReceiveResult(
                    succeeded: transport.succeeded,
                    summary: "\(summaryPrefix) \(clipboard.summary); \(sessionOpenNotes.joined(separator: " | ")); \(transport.summary)" + summarizedAttempts(attempts),
                    clipboard: clipboard,
                    transport: transport
                )
            }

            let packetSummary = ClipboardUPipeMessage.summarizeReceivedPacket(transport.data)
            let command = packetSummary.command ?? "none"
            let appCommandID = packetSummary.appCommandID ?? "none"
            attempts.append("poll\(index + 1)=command:\(command),app:\(appCommandID),transport:\(transport.summary)")

            if index + 1 < pollCount, pollIntervalMicroseconds > 0 {
                usleep(pollIntervalMicroseconds)
            }
        }

        let summaryPrefix = pollCount > 1 ? "clipboardRx no-transfer-clipboard after \(pollCount) polls" : "clipboardRx no-transfer-clipboard"
        return OTiClipboardReceiveResult(
            succeeded: sawAnyTransportSuccess || lastTransport.succeeded,
            summary: "\(summaryPrefix); \(sessionOpenNotes.joined(separator: " | ")); \(lastTransport.summary)" + summarizedAttempts(attempts),
            clipboard: nil,
            transport: lastTransport
        )
    }

    static func sendXMLCommandProbe(
        _ xml: String,
        includeCommandTerminator: Bool = false
    ) -> OTiDataProbeResult {
        let encoded = ClipboardUPipeMessage.encodeXMLGoBridgeCommand(
            xml,
            includeCommandTerminator: includeCommandTerminator
        )
        let frames = ClipboardUPipeMessage.dataOutFrames(fromCommandDataPayloads: encoded.commandDataPayloads)
        var summaries: [String] = []

        for (index, frame) in frames.enumerated() {
            let result = runDataCommand(
                name: "xmlTx[\(index + 1)/\(frames.count)]",
                cdb: dataCDB(byte1: 0x2A, byte2: 0xFF),
                payload: frame,
                receiveLength: 0,
                direction: 1
            )
            summaries.append(result.summary)

            guard result.succeeded else {
                return OTiDataProbeResult(
                    succeeded: false,
                    summary: "xmlTx failed commandID=\(String(format: "0x%02X", encoded.commandID)) commandBytes=\(encoded.commandBytes.count) frames=\(frames.count); \(summaries.joined(separator: " | "))",
                    data: []
                )
            }
        }

        let commandPrefix = encoded.commandBytes.prefix(16).map { String(format: "%02X", $0) }.joined()
        return OTiDataProbeResult(
            succeeded: true,
            summary: "xmlTx sent commandID=\(String(format: "0x%02X", encoded.commandID)) commandBytes=\(encoded.commandBytes.count) commandPrefix=\(commandPrefix) frames=\(frames.count) frameBytes=\(frames.first?.count ?? 0); \(summaries.joined(separator: " | "))",
            data: []
        )
    }

    private static func runDataCommand(
        name: String,
        cdb: [UInt8],
        payload: [UInt8]?,
        receiveLength: UInt32,
        direction: UInt8
    ) -> OTiDataProbeResult {
        let lock = SCSITransportLock()
        guard lock.acquire() else {
            return OTiDataProbeResult(succeeded: false, summary: "transport-busy", data: [])
        }
        defer { lock.release() }

        var raw = KMLinkSCSICommandResult()
        var data: [UInt8] = []
        var retryNotes: [String] = []
        var sawUSBDevice = false
        var sawSCSIService = false

        for attempt in 0..<3 {
            guard let usbService = findUSBDevice() else {
                if attempt == 0 {
                    return OTiDataProbeResult(succeeded: false, summary: "no-usb-device", data: [])
                }
                break
            }
            sawUSBDevice = true
            defer { IOObjectRelease(usbService) }

            let preparation = SCSIMediaPreparer.unmountMediaIfPresent(from: usbService)
            if attempt > 0 {
                retryNotes.append("retry\(attempt)=\(preparation)")
            }

            guard let service = firstCompactDiscService(from: usbService) else {
                usleep(200_000)
                continue
            }
            sawSCSIService = true
            defer { IOObjectRelease(service) }

            (raw, data) = executeDataCommand(
                service: service,
                cdb: cdb,
                payload: payload,
                receiveLength: receiveLength,
                direction: direction
            )

            if raw.pluginResult == 0 && raw.exclusiveResult == 0 {
                break
            }

            usleep(200_000)
        }

        if !sawUSBDevice {
            return OTiDataProbeResult(succeeded: false, summary: "no-usb-device", data: [])
        }
        if !sawSCSIService {
            return OTiDataProbeResult(succeeded: false, summary: "no-io-service", data: [])
        }

        let prefix = data.prefix(32).map { String(format: "%02X", $0) }.joined()
        let reachedDevice = raw.pluginResult == 0 && raw.exclusiveResult == 0 && raw.serviceResponse != 0
        let transferredPayload = payload.map { raw.bytesTransferred == UInt64($0.count) } ?? false
        let state: String
        if raw.result == 0 {
            state = direction == 1 ? "sent" : "packet"
        } else if direction == 1, reachedDevice, transferredPayload {
            state = "sent-check-condition"
        } else if reachedDevice {
            state = "no-packet-or-check-condition"
        } else {
            state = "transport-error"
        }
        let retryPrefix = retryNotes.isEmpty ? "" : "\(retryNotes.joined(separator: " ")) "
        let summary = "\(name) state=\(state) \(retryPrefix)result=\(raw.result) plugin=\(hex(raw.pluginResult)) exclusive=\(hex(raw.exclusiveResult)) command=\(hex(raw.commandResult)) response=\(raw.serviceResponse) status=\(raw.taskStatus) bytes=\(raw.bytesTransferred) data=\(prefix)"
        return OTiDataProbeResult(
            succeeded: raw.result == 0 || (direction == 2 && reachedDevice) || (direction == 1 && reachedDevice && transferredPayload),
            summary: summary,
            data: data
        )
    }

    private static func runDataCommandOnSession(
        _ session: OpaquePointer,
        name: String,
        cdb: [UInt8],
        payload: [UInt8]?,
        receiveLength: UInt32,
        direction: UInt8
    ) -> OTiDataProbeResult {
        let (raw, data) = executeDataCommand(
            session: session,
            cdb: cdb,
            payload: payload,
            receiveLength: receiveLength,
            direction: direction
        )
        return summarizeDataCommandResult(
            name: name,
            raw: raw,
            data: data,
            payloadLength: payload?.count,
            direction: direction
        )
    }

    private static func sendFramesOnSession(
        _ session: OpaquePointer,
        name: String,
        frames: [[UInt8]],
        commandBytes: [UInt8],
        successLabel: String
    ) -> OTiDataProbeResult {
        var summaries: [String] = []
        for (index, frame) in frames.enumerated() {
            let result = runDataCommandOnSession(
                session,
                name: "\(name)[\(index + 1)/\(frames.count)]",
                cdb: dataCDB(byte1: 0x2A, byte2: 0xFF),
                payload: frame,
                receiveLength: 0,
                direction: 1
            )
            summaries.append(result.summary)
            guard result.succeeded else {
                return OTiDataProbeResult(
                    succeeded: false,
                    summary: "\(name) failed commandBytes=\(commandBytes.count) frames=\(frames.count); \(summaries.joined(separator: " | "))",
                    data: []
                )
            }
        }

        return OTiDataProbeResult(
            succeeded: true,
            summary: "\(successLabel); \(summaries.joined(separator: " | "))",
            data: []
        )
    }

    private static func summarizeDataCommandResult(
        name: String,
        raw: KMLinkSCSICommandResult,
        data: [UInt8],
        payloadLength: Int?,
        direction: UInt8
    ) -> OTiDataProbeResult {
        let prefix = data.prefix(32).map { String(format: "%02X", $0) }.joined()
        let reachedDevice = raw.pluginResult == 0 && raw.exclusiveResult == 0 && raw.serviceResponse != 0
        let transferredPayload = payloadLength.map { raw.bytesTransferred == UInt64($0) } ?? false
        let state: String
        if raw.result == 0 {
            state = direction == 1 ? "sent" : "packet"
        } else if direction == 1, reachedDevice, transferredPayload {
            state = "sent-check-condition"
        } else if reachedDevice {
            state = "no-packet-or-check-condition"
        } else {
            state = "transport-error"
        }
        let summary = "\(name) state=\(state) result=\(raw.result) plugin=\(hex(raw.pluginResult)) exclusive=\(hex(raw.exclusiveResult)) command=\(hex(raw.commandResult)) response=\(raw.serviceResponse) status=\(raw.taskStatus) bytes=\(raw.bytesTransferred) data=\(prefix)"
        return OTiDataProbeResult(
            succeeded: raw.result == 0 || (direction == 2 && reachedDevice) || (direction == 1 && reachedDevice && transferredPayload),
            summary: summary,
            data: data
        )
    }

    private static func executeDataCommand(
        service: io_service_t,
        cdb: [UInt8],
        payload: [UInt8]?,
        receiveLength: UInt32,
        direction: UInt8
    ) -> (KMLinkSCSICommandResult, [UInt8]) {
        var raw = KMLinkSCSICommandResult()
        var capture = [UInt8](repeating: 0, count: Int(receiveLength))
        var capturedLength: UInt32 = 0
        cdb.withUnsafeBufferPointer { cdbBuffer in
            if let payload {
                payload.withUnsafeBufferPointer { payloadBuffer in
                    KMLinkSCSICommand(
                        service,
                        cdbBuffer.baseAddress,
                        UInt8(cdb.count),
                        payloadBuffer.baseAddress,
                        UInt32(payload.count),
                        receiveLength,
                        direction,
                        &raw
                    )
                }
            } else if receiveLength > 0 {
                let captureCapacity = UInt32(capture.count)
                capture.withUnsafeMutableBufferPointer { captureBuffer in
                    KMLinkSCSICommandWithDataBuffer(
                        service,
                        cdbBuffer.baseAddress,
                        UInt8(cdb.count),
                        nil,
                        0,
                        receiveLength,
                        direction,
                        captureBuffer.baseAddress,
                        captureCapacity,
                        &capturedLength,
                        &raw
                    )
                }
            } else {
                KMLinkSCSICommand(
                    service,
                    cdbBuffer.baseAddress,
                    UInt8(cdb.count),
                    nil,
                    0,
                    receiveLength,
                    direction,
                    &raw
                )
            }
        }

        let data = capturedLength > 0 ? Array(capture.prefix(Int(capturedLength))) : bytes(from: raw.data, length: Int(raw.dataLength))
        return (raw, data)
    }

    private static func executeDataCommand(
        session: OpaquePointer,
        cdb: [UInt8],
        payload: [UInt8]?,
        receiveLength: UInt32,
        direction: UInt8
    ) -> (KMLinkSCSICommandResult, [UInt8]) {
        var raw = KMLinkSCSICommandResult()
        var capture = [UInt8](repeating: 0, count: Int(receiveLength))
        var capturedLength: UInt32 = 0
        cdb.withUnsafeBufferPointer { cdbBuffer in
            if let payload {
                payload.withUnsafeBufferPointer { payloadBuffer in
                    KMLinkSCSISessionCommand(
                        session,
                        cdbBuffer.baseAddress,
                        UInt8(cdb.count),
                        payloadBuffer.baseAddress,
                        UInt32(payload.count),
                        receiveLength,
                        direction,
                        &raw
                    )
                }
            } else if receiveLength > 0 {
                let captureCapacity = UInt32(capture.count)
                capture.withUnsafeMutableBufferPointer { captureBuffer in
                    KMLinkSCSISessionCommandWithDataBuffer(
                        session,
                        cdbBuffer.baseAddress,
                        UInt8(cdb.count),
                        nil,
                        0,
                        receiveLength,
                        direction,
                        captureBuffer.baseAddress,
                        captureCapacity,
                        &capturedLength,
                        &raw
                    )
                }
            } else {
                KMLinkSCSISessionCommand(
                    session,
                    cdbBuffer.baseAddress,
                    UInt8(cdb.count),
                    nil,
                    0,
                    receiveLength,
                    direction,
                    &raw
                )
            }
        }

        let data = capturedLength > 0 ? Array(capture.prefix(Int(capturedLength))) : bytes(from: raw.data, length: Int(raw.dataLength))
        return (raw, data)
    }

    private static func dataCDB(byte1: UInt8, byte2: UInt8) -> [UInt8] {
        var cdb = [UInt8](repeating: 0, count: 16)
        cdb[0] = 0xD9
        cdb[1] = byte1
        cdb[2] = byte2
        cdb[14] = 0x4F
        cdb[15] = 0x54
        return cdb
    }

    private static func findUSBDevice() -> io_service_t? {
        let matching = IOServiceMatching("IOUSBDevice") as NSMutableDictionary
        matching["idVendor"] = NSNumber(value: USBDeviceMonitor.vendorID)
        matching["idProduct"] = NSNumber(value: USBDeviceMonitor.productID)

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        return service == 0 ? nil : service
    }

    private static func firstCompactDiscService(from root: io_registry_entry_t) -> io_service_t? {
        var found: io_service_t?

        func visit(_ node: io_registry_entry_t, depth: Int) {
            guard found == nil, depth <= 8 else {
                return
            }

            var iterator: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(node, kIOServicePlane, &iterator) == KERN_SUCCESS else {
                return
            }
            defer { IOObjectRelease(iterator) }

            while found == nil {
                let child = IOIteratorNext(iterator)
                if child == 0 {
                    break
                }
                defer { IOObjectRelease(child) }

                if TransportProbe.className(child) == "IOCompactDiscServices" {
                    IOObjectRetain(child)
                    found = child
                    return
                }
                visit(child, depth: depth + 1)
            }
        }

        visit(root, depth: 0)
        return found
    }

    private static func hex(_ value: Int32) -> String {
        String(format: "0x%08X", UInt32(bitPattern: value))
    }

    private static func bytes<T>(from tuple: T, length: Int) -> [UInt8] {
        var copy = tuple
        return withUnsafeBytes(of: &copy) { rawBuffer in
            Array(rawBuffer.prefix(max(0, min(length, rawBuffer.count))))
        }
    }

    private static func summarizedAttempts(_ attempts: [String]) -> String {
        guard !attempts.isEmpty else {
            return ""
        }
        let tail = attempts.suffix(4).joined(separator: " | ")
        return " | attempts=\(tail)"
    }
}
