import Foundation

enum ClipboardUPipeMessage {
    enum LegacyHeaderMode {
        case perCommandSession
        case mirroredPacketSerial
    }

    private struct LegacyCommandSenderState {
        var transferSessionID: UInt32 = 0
        var packetSerial: UInt32 = 0
        var headerMode: LegacyHeaderMode = .perCommandSession

        mutating func nextCommandReservation(chunkCount: Int) -> (transferSessionID: UInt32, packetSerialStart: UInt32) {
            if transferSessionID == 0 {
                transferSessionID = 1
            }

            let start = packetSerial &+ 1
            packetSerial &+= UInt32(chunkCount)
            let currentTransferSessionID: UInt32
            switch headerMode {
            case .perCommandSession:
                currentTransferSessionID = transferSessionID
                transferSessionID &+= 1
                if transferSessionID == 0 {
                    transferSessionID = 1
                }
            case .mirroredPacketSerial:
                currentTransferSessionID = start
                transferSessionID = packetSerial &+ 1
                if transferSessionID == 0 {
                    transferSessionID = 1
                }
            }
            return (currentTransferSessionID, start)
        }
    }

    enum Format: String {
        case text = "CB_Format_Text"
        case unicodeText = "CB_Format_UnicodeText"
    }

    struct Encoded {
        let format: Format
        let xml: String
        let bytes: [UInt8]
        let frames: [[UInt8]]
    }

    struct GoBridgeEncoded {
        let format: Format
        let xml: String
        let commandID: UInt8
        let commandBytes: [UInt8]
        let commandDataPayloads: [[UInt8]]
        let frames: [[UInt8]]
    }

    struct CommandEncoded {
        let commandID: UInt8
        let commandBytes: [UInt8]
        let commandDataPayloads: [[UInt8]]
        let frames: [[UInt8]]
    }

    enum InnerXMLMode {
        case escaped
        case raw
    }

    enum ContentField {
        case content
        case contentText

        var tag: String {
            switch self {
            case .content:
                return "CP_Content"
            case .contentText:
                return "CP_Content_Text"
            }
        }
    }

    enum UnicodeContentPrefix {
        case none
        case bom
    }

    enum UnicodeTerminator {
        case nul
        case none
    }

    enum UnicodeByteOrder {
        case little
        case big
    }

    enum ContentEnvelope {
        case lengthAndBytes
        case rawHex
    }

    enum CommandLengthEndian {
        case big
        case little
    }

    struct ReceivedClipboard {
        let command: String
        let format: Format
        let text: String
        let contentBytes: Int

        var summary: String {
            "\(command) \(format.rawValue) text \(text.count) chars contentBytes=\(contentBytes)"
        }
    }

    struct ReceivedSummary {
        let hasPacket: Bool
        let mirrorValid: Bool
        let isDummy: Bool
        let payloadBytes: Int
        let firstNonZeroOffset: Int?
        let transportHeaderLE: String
        let appCommandOffset: Int?
        let appCommandID: String?
        let appHeaderHex: String
        let frameMagic: String?
        let frameMagicOffset: Int?
        let frameLabel: String?
        let frameLabelOffset: Int?
        let frameDataOffset: Int?
        let headerHex: String
        let xmlOffset: Int?
        let command: String?
        let clipboardFormat: String?
        let contentHexBytes: Int?
        let preview: String

        var lines: [String] {
            [
                "clipboard.rx.hasPacket: \(hasPacket)",
                "clipboard.rx.mirrorValid: \(mirrorValid)",
                "clipboard.rx.isDummy: \(isDummy)",
                "clipboard.rx.payloadBytes: \(payloadBytes)",
                "clipboard.rx.firstNonZeroOffset: \(firstNonZeroOffset.map(String.init) ?? "none")",
                "clipboard.rx.transportHeaderLE: \(transportHeaderLE)",
                "clipboard.rx.appCommandOffset: \(appCommandOffset.map(String.init) ?? "none")",
                "clipboard.rx.appCommandID: \(appCommandID ?? "none")",
                "clipboard.rx.appHeaderHex: \(appHeaderHex)",
                "clipboard.rx.frameMagic: \(frameMagic ?? "none")",
                "clipboard.rx.frameMagicOffset: \(frameMagicOffset.map(String.init) ?? "none")",
                "clipboard.rx.frameLabel: \(frameLabel ?? "none")",
                "clipboard.rx.frameLabelOffset: \(frameLabelOffset.map(String.init) ?? "none")",
                "clipboard.rx.frameDataOffset: \(frameDataOffset.map(String.init) ?? "none")",
                "clipboard.rx.headerHex: \(headerHex)",
                "clipboard.rx.xmlOffset: \(xmlOffset.map(String.init) ?? "none")",
                "clipboard.rx.command: \(command ?? "none")",
                "clipboard.rx.format: \(clipboardFormat ?? "none")",
                "clipboard.rx.contentHexBytes: \(contentHexBytes.map(String.init) ?? "none")",
                "clipboard.rx.preview: \(preview)"
            ]
        }
    }

    static let packetPayloadLength = 0xFFEC
    static let packetLength = 0x10000
    static let commandDataHeaderLength = 20
    static let maxCommandDataChunkLength = packetPayloadLength - commandDataHeaderLength
    private static let mirrorTailLength = 20
    private static var legacyCommandSenderState = LegacyCommandSenderState()

    static func encodeText(_ text: String, format: Format = .unicodeText) -> Encoded {
        let message = upipeXML(forText: text, format: format)
        let bytes = Array(message.utf8)
        return Encoded(
            format: format,
            xml: message,
            bytes: bytes,
            frames: makeFrames(from: bytes)
        )
    }

    static func encodeTextGoBridgeCommand(
        _ text: String,
        format: Format = .unicodeText,
        innerXMLMode: InnerXMLMode = .escaped,
        contentField: ContentField = .content,
        unicodePrefix: UnicodeContentPrefix = .none,
        unicodeTerminator: UnicodeTerminator = .nul,
        unicodeByteOrder: UnicodeByteOrder = .little,
        contentEnvelope: ContentEnvelope = .lengthAndBytes,
        commandLengthEndian: CommandLengthEndian = .big,
        includeCommandTerminator: Bool = false,
        transferSessionID: UInt32? = nil,
        packetSerialStart: UInt32? = nil
    ) -> GoBridgeEncoded {
        let message = upipeXML(
            forText: text,
            format: format,
            innerXMLMode: innerXMLMode,
            contentField: contentField,
            unicodePrefix: unicodePrefix,
            unicodeTerminator: unicodeTerminator,
            unicodeByteOrder: unicodeByteOrder,
            contentEnvelope: contentEnvelope
        )
        let command = goBridgeXMLCommand(for: message, lengthEndian: commandLengthEndian)
        let reservation = reserveLegacyCommandHeadersIfNeeded(
            commandBytes: command,
            transferSessionID: transferSessionID,
            packetSerialStart: packetSerialStart
        )
        let payloads = commandDataPayloads(
            from: command,
            transferSessionID: reservation.transferSessionID,
            packetSerialStart: reservation.packetSerialStart,
            includeTerminator: includeCommandTerminator
        )
        return GoBridgeEncoded(
            format: format,
            xml: message,
            commandID: command.first ?? 0,
            commandBytes: command,
            commandDataPayloads: payloads,
            frames: payloads.map(makeFrame(fromPayload:))
        )
    }

    static func encodeXMLGoBridgeCommand(
        _ xml: String,
        commandLengthEndian: CommandLengthEndian = .big,
        includeCommandTerminator: Bool = false,
        transferSessionID: UInt32? = nil,
        packetSerialStart: UInt32? = nil
    ) -> CommandEncoded {
        let command = goBridgeXMLCommand(for: xml, lengthEndian: commandLengthEndian)
        let reservation = reserveLegacyCommandHeadersIfNeeded(
            commandBytes: command,
            transferSessionID: transferSessionID,
            packetSerialStart: packetSerialStart
        )
        let payloads = commandDataPayloads(
            from: command,
            transferSessionID: reservation.transferSessionID,
            packetSerialStart: reservation.packetSerialStart,
            includeTerminator: includeCommandTerminator
        )
        return CommandEncoded(
            commandID: command.first ?? 0,
            commandBytes: command,
            commandDataPayloads: payloads,
            frames: payloads.map(makeFrame(fromPayload:))
        )
    }

    static func encodeLoginGoBridgeCommand(
        name: String = "TXLIN1",
        osVersion: UInt8 = 0x07,
        loginSiteCodePage: UInt16 = 0,
        includeCommandTerminator: Bool = false,
        transferSessionID: UInt32? = nil,
        packetSerialStart: UInt32? = nil
    ) -> CommandEncoded {
        let nameBytes = Array(name.utf8.prefix(255))
        var command: [UInt8] = [0x01, osVersion]
        command.append(UInt8((loginSiteCodePage >> 8) & 0xFF))
        command.append(UInt8(loginSiteCodePage & 0xFF))
        command.append(UInt8(nameBytes.count))
        command.append(contentsOf: nameBytes)
        let reservation = reserveLegacyCommandHeadersIfNeeded(
            commandBytes: command,
            transferSessionID: transferSessionID,
            packetSerialStart: packetSerialStart
        )
        let payloads = commandDataPayloads(
            from: command,
            transferSessionID: reservation.transferSessionID,
            packetSerialStart: reservation.packetSerialStart,
            includeTerminator: includeCommandTerminator
        )
        return CommandEncoded(
            commandID: command.first ?? 0,
            commandBytes: command,
            commandDataPayloads: payloads,
            frames: payloads.map(makeFrame(fromPayload:))
        )
    }

    static func encodeRawCommand(
        commandID: UInt8,
        payload: [UInt8] = [],
        includeCommandTerminator: Bool = false,
        transferSessionID: UInt32? = nil,
        packetSerialStart: UInt32? = nil
    ) -> CommandEncoded {
        var command = [commandID]
        command.append(contentsOf: payload)
        let reservation = reserveLegacyCommandHeadersIfNeeded(
            commandBytes: command,
            transferSessionID: transferSessionID,
            packetSerialStart: packetSerialStart
        )
        let payloads = commandDataPayloads(
            from: command,
            transferSessionID: reservation.transferSessionID,
            packetSerialStart: reservation.packetSerialStart,
            includeTerminator: includeCommandTerminator
        )
        return CommandEncoded(
            commandID: commandID,
            commandBytes: command,
            commandDataPayloads: payloads,
            frames: payloads.map(makeFrame(fromPayload:))
        )
    }

    private static func upipeXML(
        forText text: String,
        format: Format,
        innerXMLMode: InnerXMLMode = .escaped,
        contentField: ContentField = .content,
        unicodePrefix: UnicodeContentPrefix = .none,
        unicodeTerminator: UnicodeTerminator = .nul,
        unicodeByteOrder: UnicodeByteOrder = .little,
        contentEnvelope: ContentEnvelope = .lengthAndBytes
    ) -> String {
        let contentHex: String
        let contentBytes: Int
        switch format {
        case .text:
            contentHex = unicodeTextHex(text, prefix: unicodePrefix, terminator: unicodeTerminator, byteOrder: unicodeByteOrder)
            contentBytes = contentHex.count / 2
        case .unicodeText:
            contentHex = unicodeTextHex(text, prefix: unicodePrefix, terminator: unicodeTerminator, byteOrder: unicodeByteOrder)
            contentBytes = contentHex.count / 2
        }
        let contentValue: String
        switch contentEnvelope {
        case .lengthAndBytes:
            contentValue = "LENGTH=\(contentBytes),BYTES=0X\(contentHex)"
        case .rawHex:
            contentValue = contentHex
        }

        let clipboardInfo = xml([
            (contentField.tag, contentValue),
            ("CB_Format_Type", format.rawValue)
        ])
        switch innerXMLMode {
        case .escaped:
            return xml([
                ("Param_Clipboard_Info_2", clipboardInfo),
                ("NP_Cmd", "Cmd_Transfer_Clipboard"),
                ("NP_Up_Notice_NamePipe_Name", #"\\.\pipe\OTI_ClipboardAgent"#)
            ])
        case .raw:
            return "<OTIMSG>"
                + "<Param_Clipboard_Info_2>\(clipboardInfo)</Param_Clipboard_Info_2>"
                + "<NP_Cmd>Cmd_Transfer_Clipboard</NP_Cmd>"
                + #"<NP_Up_Notice_NamePipe_Name>\\.\pipe\OTI_ClipboardAgent</NP_Up_Notice_NamePipe_Name>"#
                + "</OTIMSG>"
        }
    }

    private static func goBridgeXMLCommand(for xml: String, lengthEndian: CommandLengthEndian = .big) -> [UInt8] {
        let wrappedXML = "<ExtraXmlCommand>HookAppService</ExtraXmlCommand><ExtraXmlParam>\(xml)</ExtraXmlParam>"
        let xmlBytes = Array(wrappedXML.utf8)
        var command: [UInt8] = [0x39]
        switch lengthEndian {
        case .big:
            command.append(contentsOf: UInt32(xmlBytes.count).bigEndianBytes)
        case .little:
            command.append(contentsOf: UInt32(xmlBytes.count).littleEndianBytes)
        }
        command.append(contentsOf: xmlBytes)
        return command
    }

    static func validateFrames(_ frames: [[UInt8]]) -> Bool {
        frames.allSatisfy { frame in
            guard frame.count == packetLength else {
                return false
            }
            return Array(frame.prefix(mirrorTailLength)) == Array(frame.suffix(mirrorTailLength))
        }
    }

    static func commandDataHeaderValues(from bytes: [UInt8]) -> [UInt32]? {
        guard bytes.count >= commandDataHeaderLength else {
            return nil
        }

        return stride(from: 0, to: commandDataHeaderLength, by: 4).map { offset in
            u32LE(bytes, at: offset)
        }
    }

    static func commandXMLLength(from commandBytes: [UInt8]) -> UInt32? {
        guard commandBytes.count >= 5 else {
            return nil
        }
        return u32BE(commandBytes, at: 1)
    }

    static func dataOutFrames(fromCommandDataPayloads payloads: [[UInt8]]) -> [[UInt8]] {
        payloads.map(makeFrame(fromPayload:))
    }

    static func clipboardText(fromReceivedPacket packet: [UInt8]) -> ReceivedClipboard? {
        guard packet.count == packetLength else {
            return nil
        }

        let payload = Array(packet.prefix(packetPayloadLength))
        guard Array(packet.prefix(mirrorTailLength)) == Array(packet.suffix(mirrorTailLength)),
              let xmlString = xmlString(fromPayload: payload) else {
            return nil
        }

        return clipboardText(fromXML: xmlString)
    }

    static func xmlString(fromReceivedPacket packet: [UInt8]) -> String? {
        guard packet.count == packetLength else {
            return nil
        }
        return xmlString(fromPayload: Array(packet.prefix(packetPayloadLength)))
    }

    static func summarizeReceivedPacket(_ packet: [UInt8]) -> ReceivedSummary {
        guard packet.count == packetLength else {
            return ReceivedSummary(
                hasPacket: false,
                mirrorValid: false,
                isDummy: packet.allSatisfy { $0 == 0 },
                payloadBytes: packet.count,
                firstNonZeroOffset: firstNonZeroOffset(in: packet),
                transportHeaderLE: u32LESummary(Array(packet.prefix(mirrorTailLength))),
                appCommandOffset: nil,
                appCommandID: nil,
                appHeaderHex: "",
                frameMagic: nil,
                frameMagicOffset: nil,
                frameLabel: nil,
                frameLabelOffset: nil,
                frameDataOffset: nil,
                headerHex: hex(Array(packet.prefix(32))),
                xmlOffset: nil,
                command: nil,
                clipboardFormat: nil,
                contentHexBytes: nil,
                preview: preview(packet)
            )
        }

        let mirrorValid = Array(packet.prefix(mirrorTailLength)) == Array(packet.suffix(mirrorTailLength))
        let payload = Array(packet.prefix(packetPayloadLength))
        let isDummy = payload.allSatisfy { $0 == 0 }
        let xmlOffset = findNeedle(Array("<OTIMSG>".utf8), in: payload)
        let magic = frameMagic(in: payload)
        let label = magic.flatMap { labeledField(endingAtMagic: $0.offset, in: payload) }
        let appOffset = mirrorTailLength
        let xmlString = xmlOffset.flatMap { extractXMLString(from: payload, startingAt: $0) }
        let receivedClipboard = xmlString.flatMap(clipboardText(fromXML:))
        let contentHex = receivedClipboard.map { String(repeating: "00", count: $0.contentBytes) }
            ?? xmlString.flatMap { value(for: "CP_Content", in: $0) ?? value(for: "CP_Content_Text", in: $0) }
        return ReceivedSummary(
            hasPacket: mirrorValid && !isDummy,
            mirrorValid: mirrorValid,
            isDummy: isDummy,
            payloadBytes: payload.count,
            firstNonZeroOffset: firstNonZeroOffset(in: payload),
            transportHeaderLE: u32LESummary(Array(payload.prefix(mirrorTailLength))),
            appCommandOffset: appOffset < payload.count ? appOffset : nil,
            appCommandID: appOffset < payload.count ? String(format: "0x%02X", payload[appOffset]) : nil,
            appHeaderHex: appOffset < payload.count ? hex(Array(payload[appOffset..<min(appOffset + 16, payload.count)])) : "",
            frameMagic: magic?.name,
            frameMagicOffset: magic?.offset,
            frameLabel: label?.text,
            frameLabelOffset: label?.offset,
            frameDataOffset: label?.dataOffset,
            headerHex: hex(Array(payload.prefix(32))),
            xmlOffset: xmlOffset,
            command: xmlString.flatMap { value(for: "NP_Cmd", in: $0) },
            clipboardFormat: receivedClipboard?.format.rawValue ?? xmlString.flatMap { value(for: "CB_Format_Type", in: $0) },
            contentHexBytes: contentHex.map { $0.count / 2 },
            preview: preview(xmlString.map { Array($0.utf8) } ?? payload)
        )
    }

    private static func clipboardText(fromXML xmlString: String) -> ReceivedClipboard? {
        guard let command = value(for: "NP_Cmd", in: xmlString),
              command == "Cmd_Transfer_Clipboard" else {
            return nil
        }

        let innerXML: String
        if let escapedInnerXML = value(for: "Param_Clipboard_Info_2", in: xmlString) {
            innerXML = unescapeXML(escapedInnerXML)
        } else {
            innerXML = xmlString
        }

        guard let formatValue = value(for: "CB_Format_Type", in: innerXML),
              let format = Format(rawValue: formatValue),
              let contentHex = value(for: "CP_Content", in: innerXML) ?? value(for: "CP_Content_Text", in: innerXML),
              let contentBytes = bytes(fromHex: contentHex),
              let text = decodeClipboardContent(contentBytes, format: format) else {
            return nil
        }

        return ReceivedClipboard(
            command: command,
            format: format,
            text: text,
            contentBytes: contentBytes.count
        )
    }

    private static func makeFrames(from bytes: [UInt8]) -> [[UInt8]] {
        let chunks = bytes.isEmpty ? [[]] : stride(from: 0, to: bytes.count, by: packetPayloadLength).map {
            Array(bytes[$0..<min($0 + packetPayloadLength, bytes.count)])
        }

        return chunks.map(makeFrame(fromPayload:))
    }

    private static func commandDataPayloads(
        from commandBytes: [UInt8],
        transferSessionID: UInt32 = 1,
        packetSerialStart: UInt32 = 1,
        includeTerminator: Bool = false
    ) -> [[UInt8]] {
        let chunks = commandBytes.isEmpty ? [[]] : stride(from: 0, to: commandBytes.count, by: maxCommandDataChunkLength).map {
            Array(commandBytes[$0..<min($0 + maxCommandDataChunkLength, commandBytes.count)])
        }
        let totalChunks = UInt32(chunks.count)

        var payloads = chunks.enumerated().map { index, chunk in
            var payload: [UInt8] = []
            payload.reserveCapacity(commandDataHeaderLength + chunk.count)
            payload.append(contentsOf: (packetSerialStart + UInt32(index)).littleEndianBytes)
            payload.append(contentsOf: transferSessionID.littleEndianBytes)
            payload.append(contentsOf: UInt32(index).littleEndianBytes)
            payload.append(contentsOf: totalChunks.littleEndianBytes)
            payload.append(contentsOf: UInt32(chunk.count).littleEndianBytes)
            payload.append(contentsOf: chunk)
            return payload
        }
        if includeTerminator {
            payloads.append([UInt8](repeating: 0, count: commandDataHeaderLength))
        }
        return payloads
    }

    static func resetLegacyCommandSenderState() {
        legacyCommandSenderState = LegacyCommandSenderState()
    }

    static func setLegacyHeaderMode(_ mode: LegacyHeaderMode) {
        legacyCommandSenderState.headerMode = mode
    }

    private static func reserveLegacyCommandHeadersIfNeeded(
        commandBytes: [UInt8],
        transferSessionID: UInt32?,
        packetSerialStart: UInt32?
    ) -> (transferSessionID: UInt32, packetSerialStart: UInt32) {
        if let transferSessionID, let packetSerialStart {
            return (transferSessionID, packetSerialStart)
        }

        let chunkCount = max(
            1,
            Int(ceil(Double(commandBytes.count) / Double(maxCommandDataChunkLength)))
        )
        let reservation = legacyCommandSenderState.nextCommandReservation(chunkCount: chunkCount)
        return (
            transferSessionID ?? reservation.transferSessionID,
            packetSerialStart ?? reservation.packetSerialStart
        )
    }

    private static func makeFrame(fromPayload payloadBytes: [UInt8]) -> [UInt8] {
        let payload = makeDataOutFrame(fromPayload: payloadBytes)
        return payload + payload.prefix(mirrorTailLength)
    }

    private static func makeDataOutFrame(fromPayload payloadBytes: [UInt8]) -> [UInt8] {
        let chunk = Array(payloadBytes.prefix(packetPayloadLength))
        var payload = [UInt8](repeating: 0, count: packetPayloadLength)
        if !chunk.isEmpty {
            payload.replaceSubrange(0..<chunk.count, with: chunk)
        }
        return payload
    }

    private static func xml(_ fields: [(String, String)]) -> String {
        var result = "<OTIMSG>"
        for (key, value) in fields {
            result += "<\(key)>\(escapeXML(value))</\(key)>"
        }
        result += "</OTIMSG>"
        return result
    }

    private static func escapeXML(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for char in value {
            switch char {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&dq;"
            default: escaped.append(char)
            }
        }
        return escaped
    }

    private static func unescapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&dq;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func value(for tag: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(tag)>"),
              let close = xml.range(of: "</\(tag)>", range: open.upperBound..<xml.endIndex) else {
            return nil
        }
        return String(xml[open.upperBound..<close.lowerBound])
    }

    private static func extractXMLString(from bytes: [UInt8], startingAt offset: Int) -> String? {
        let endNeedle = Array("</OTIMSG>".utf8)
        guard let relativeEnd = findNeedle(endNeedle, in: Array(bytes.dropFirst(offset))) else {
            return String(bytes: bytes.dropFirst(offset).prefix(512), encoding: .utf8)
        }

        let end = offset + relativeEnd + endNeedle.count
        guard end <= bytes.count else {
            return nil
        }
        return String(bytes: bytes[offset..<end], encoding: .utf8)
    }

    private static func xmlString(fromPayload payload: [UInt8]) -> String? {
        guard let xmlOffset = findNeedle(Array("<OTIMSG>".utf8), in: payload) else {
            return nil
        }
        return extractXMLString(from: payload, startingAt: xmlOffset)
    }

    private static func findNeedle(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else {
            return nil
        }
        for index in 0...(haystack.count - needle.count) where Array(haystack[index..<(index + needle.count)]) == needle {
            return index
        }
        return nil
    }

    private static func frameMagic(in bytes: [UInt8]) -> (name: String, offset: Int)? {
        for name in ["TXLIN1", "XMLIN1", "OTIMSG"] {
            if let offset = findNeedle(Array(name.utf8), in: bytes) {
                return (name, offset)
            }
        }
        return nil
    }

    private static func labeledField(endingAtMagic magicOffset: Int, in bytes: [UInt8]) -> (text: String, offset: Int, dataOffset: Int)? {
        guard magicOffset > 0 else {
            return nil
        }
        let lengthOffset = magicOffset - 1
        let length = Int(bytes[lengthOffset])
        guard length > 0, length <= 64, magicOffset + length <= bytes.count else {
            return nil
        }
        let labelBytes = Array(bytes[magicOffset..<(magicOffset + length)])
        guard let label = String(bytes: labelBytes, encoding: .ascii),
              label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
            return nil
        }
        return (label, lengthOffset, magicOffset + length)
    }

    private static func firstNonZeroOffset(in bytes: [UInt8]) -> Int? {
        bytes.firstIndex { $0 != 0 }
    }

    private static func preview(_ bytes: [UInt8]) -> String {
        let printable = bytes.prefix(160).map { byte -> Character in
            if byte >= 0x20 && byte <= 0x7E {
                return Character(UnicodeScalar(byte))
            }
            return "."
        }
        return String(printable)
    }

    private static func u32LESummary(_ bytes: [UInt8]) -> String {
        stride(from: 0, to: min(bytes.count, mirrorTailLength), by: 4).map { offset in
            guard offset + 4 <= bytes.count else {
                return ""
            }
            let value = u32LE(bytes, at: offset)
            return String(format: "%02d:0x%08X/%u", offset, value, value)
        }
        .filter { !$0.isEmpty }
        .joined(separator: ",")
    }

    private static func u32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        let b0 = UInt32(bytes[offset])
        let b1 = UInt32(bytes[offset + 1]) << 8
        let b2 = UInt32(bytes[offset + 2]) << 16
        let b3 = UInt32(bytes[offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }

    private static func u32BE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        let b0 = UInt32(bytes[offset]) << 24
        let b1 = UInt32(bytes[offset + 1]) << 16
        let b2 = UInt32(bytes[offset + 2]) << 8
        let b3 = UInt32(bytes[offset + 3])
        return b0 | b1 | b2 | b3
    }

    private static func unicodeTextHex(
        _ text: String,
        prefix: UnicodeContentPrefix = .none,
        terminator: UnicodeTerminator = .nul,
        byteOrder: UnicodeByteOrder = .little
    ) -> String {
        let normalized = normalizeLineEndingsForWindows(text)
        var bytes: [UInt8] = []
        bytes.reserveCapacity((normalized.utf16.count + 1) * 2)
        if prefix == .bom {
            bytes.append(0xFF)
            bytes.append(0xFE)
        }
        for unit in normalized.utf16 {
            switch byteOrder {
            case .little:
                bytes.append(UInt8(unit & 0x00FF))
                bytes.append(UInt8((unit >> 8) & 0x00FF))
            case .big:
                bytes.append(UInt8((unit >> 8) & 0x00FF))
                bytes.append(UInt8(unit & 0x00FF))
            }
        }
        if terminator == .nul {
            bytes.append(0)
            bytes.append(0)
        }
        return hex(bytes)
    }

    private static func normalizeLineEndingsForWindows(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if char == "\r" {
                let next = text.index(after: index)
                result += "\r\n"
                index = next < text.endIndex && text[next] == "\n" ? text.index(after: next) : next
            } else if char == "\n" {
                result += "\r\n"
                index = text.index(after: index)
            } else {
                result.append(char)
                index = text.index(after: index)
            }
        }
        return result
    }

    private static func decodeClipboardContent(_ bytes: [UInt8], format: Format) -> String? {
        switch format {
        case .text:
            if bytes.count >= 2,
               bytes.indices.contains(1),
               bytes[1] == 0 {
                return decodeUTF16LE(bytes)
            }
            let content = bytes.split(separator: 0, maxSplits: 1, omittingEmptySubsequences: false).first.map(Array.init) ?? bytes
            return String(bytes: content, encoding: .utf8)
        case .unicodeText:
            return decodeUTF16LE(bytes)
        }
    }

    private static func bytes(fromHex hex: String) -> [UInt8]? {
        let compact: String
        if let range = hex.range(of: "BYTES=0X", options: .caseInsensitive) {
            compact = String(hex[range.upperBound...]).filter { !$0.isWhitespace }
        } else {
            compact = hex.filter { !$0.isWhitespace }
        }
        guard compact.count.isMultiple(of: 2) else {
            return nil
        }

        var result: [UInt8] = []
        result.reserveCapacity(compact.count / 2)
        var index = compact.startIndex
        while index < compact.endIndex {
            let next = compact.index(index, offsetBy: 2)
            guard let byte = UInt8(compact[index..<next], radix: 16) else {
                return nil
            }
            result.append(byte)
            index = next
        }
        return result
    }

    private static func decodeUTF16LE(_ bytes: [UInt8]) -> String? {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var index = 0
        while index + 1 < bytes.count {
            let unit = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
            if unit == 0 {
                break
            }
            units.append(unit)
            index += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }
}

private extension UInt32 {
    var bigEndianBytes: [UInt8] {
        [
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF)
        ]
    }

    var littleEndianBytes: [UInt8] {
        [
            UInt8(self & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 24) & 0xFF)
        ]
    }
}
