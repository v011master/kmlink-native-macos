import ApplicationServices
import Foundation
import IOKit
import KMLinkNativeCSCSI

enum HIDForwardKind: UInt8 {
    case mouse = 0x33
    case keyboard = 0x34
    case multimedia = 0x36
}

struct HIDForwardResult {
    let succeeded: Bool
    let summary: String
}

struct HIDForwardBurstResult {
    let sent: Int
    let failed: Int
    let elapsedMilliseconds: Int
    let lastSummary: String

    var succeeded: Bool {
        failed == 0
    }

    var summary: String {
        "sent=\(sent) failed=\(failed) elapsed=\(elapsedMilliseconds)ms last=\(lastSummary)"
    }
}

struct HIDTextResult {
    let succeeded: Bool
    let attemptedCharacters: Int
    let sentReports: Int
    let failedReports: Int
    let unsupportedCharacters: String
    let lastSummary: String

    var summary: String {
        let unsupported = unsupportedCharacters.isEmpty ? "none" : unsupportedCharacters
        return "chars=\(attemptedCharacters) reportsSent=\(sentReports) reportsFailed=\(failedReports) unsupported=\(unsupported) last=\(lastSummary)"
    }
}

final class OTiHIDTransport {
    var onChange: (() -> Void)?

    private let queue = DispatchQueue(label: "KMLinkNative.OTiHIDTransport")
    private var lastMouseSend = Date.distantPast
    private var pressedKeys = Set<UInt8>()
    private var modifierByte: UInt8 = 0
    private var session: OpaquePointer?
    private let transportLock = SCSITransportLock()

    private(set) var sentCount = 0
    private(set) var failedCount = 0
    private(set) var lastSummary = "idle"

    var statusLine: String {
        "HID forward: sent=\(sentCount) failed=\(failedCount) last=\(lastSummary)"
    }

    deinit {
        closeSession()
    }

    func sendKeyboardReleaseForDiagnostics() -> HIDForwardResult {
        send(kind: .keyboard, report: [UInt8](repeating: 0, count: 12))
    }

    func sendKeyboardUsageForDiagnostics(_ usage: UInt8, modifier: UInt8 = 0) -> HIDForwardBurstResult {
        var press = [UInt8](repeating: 0, count: 12)
        press[0] = modifier
        press[2] = usage
        let release = [UInt8](repeating: 0, count: 12)
        return sendKeyboardReportSequenceForDiagnostics([press, release])
    }

    func sendMouseNudgeForDiagnostics() -> HIDForwardResult {
        var report = [UInt8](repeating: 0, count: 12)
        report[0] = 0x01
        report[1] = 8
        return send(kind: .mouse, report: report)
    }

    func sendMouseLeftClickForDiagnostics() -> HIDForwardBurstResult {
        var down = [UInt8](repeating: 0, count: 12)
        down[0] = 0x01
        let up = [UInt8](repeating: 0, count: 12)
        return sendMouseReportSequenceForDiagnostics([down, up])
    }

    func sendScrollForDiagnostics(verticalDelta: Int8 = -4) -> HIDForwardBurstResult {
        var report = [UInt8](repeating: 0, count: 12)
        report[3] = UInt8(bitPattern: verticalDelta)
        let release = [UInt8](repeating: 0, count: 12)
        return sendMouseReportSequenceForDiagnostics([report, release])
    }

    func sendKeyboardReleaseBurstForDiagnostics(count: Int) -> HIDForwardBurstResult {
        let start = Date()
        var sent = 0
        var failed = 0
        var lastSummary = "none"

        for _ in 0..<max(0, count) {
            let result = sendKeyboardReleaseForDiagnostics()
            lastSummary = result.summary
            if result.succeeded {
                sent += 1
            } else {
                failed += 1
            }
        }

        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        return HIDForwardBurstResult(
            sent: sent,
            failed: failed,
            elapsedMilliseconds: elapsed,
            lastSummary: lastSummary
        )
    }

    private func sendMouseReportSequenceForDiagnostics(_ reports: [[UInt8]]) -> HIDForwardBurstResult {
        sendReportSequenceForDiagnostics(kind: .mouse, reports)
    }

    private func sendKeyboardReportSequenceForDiagnostics(_ reports: [[UInt8]]) -> HIDForwardBurstResult {
        sendReportSequenceForDiagnostics(kind: .keyboard, reports)
    }

    private func sendReportSequenceForDiagnostics(kind: HIDForwardKind, _ reports: [[UInt8]]) -> HIDForwardBurstResult {
        let start = Date()
        var sent = 0
        var failed = 0
        var lastSummary = "none"

        for report in reports {
            let result = send(kind: kind, report: report)
            lastSummary = result.summary
            if result.succeeded {
                sent += 1
            } else {
                failed += 1
            }
        }

        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        return HIDForwardBurstResult(
            sent: sent,
            failed: failed,
            elapsedMilliseconds: elapsed,
            lastSummary: lastSummary
        )
    }

    func sendASCIITextForDiagnostics(_ text: String, delayMilliseconds: UInt32 = 25) -> HIDTextResult {
        let release = [UInt8](repeating: 0, count: 12)
        var sent = 0
        var failed = 0
        var lastSummary = "none"
        var unsupported = ""

        for character in text {
            guard let key = Self.asciiKey(for: character) else {
                unsupported.append(character)
                continue
            }

            var report = [UInt8](repeating: 0, count: 12)
            report[0] = key.modifier
            report[2] = key.usage

            for nextReport in [report, release, release] {
                let result = send(kind: .keyboard, report: nextReport)
                lastSummary = result.summary
                if result.succeeded {
                    sent += 1
                } else {
                    failed += 1
                }
                usleep(delayMilliseconds * 1000)
            }
        }

        return HIDTextResult(
            succeeded: failed == 0 && unsupported.isEmpty,
            attemptedCharacters: text.count,
            sentReports: sent,
            failedReports: failed,
            unsupportedCharacters: unsupported,
            lastSummary: lastSummary
        )
    }

    func enqueue(event: CGEvent, type: CGEventType) {
        let packet = makePacket(event: event, type: type)
        guard let packet else {
            return
        }

        queue.async { [weak self] in
            guard let self else {
                return
            }
            let result = self.send(kind: packet.kind, report: packet.report)
            DispatchQueue.main.async {
                self.sentCount += result.succeeded ? 1 : 0
                self.failedCount += result.succeeded ? 0 : 1
                self.lastSummary = result.summary
                self.onChange?()
            }
        }
    }

    private func send(kind: HIDForwardKind, report: [UInt8]) -> HIDForwardResult {
        guard report.count == 12 else {
            return HIDForwardResult(succeeded: false, summary: "bad-report-size")
        }
        var cdb = [UInt8](repeating: 0, count: 16)
        cdb[0] = 0xD9
        cdb[1] = kind.rawValue
        for index in 0..<12 {
            cdb[index + 2] = report[index]
        }
        cdb[14] = 0x4F
        cdb[15] = 0x54

        let sessionResult = openSessionIfNeeded()
        guard sessionResult.succeeded else {
            return sessionResult
        }

        let raw = run(cdb: cdb)
        if raw.result == 0 {
            return HIDForwardResult(succeeded: true, summary: "\(kind) ok")
        }

        closeSession()
        return HIDForwardResult(
            succeeded: false,
            summary: "\(kind) result=\(raw.result) plugin=\(hex(raw.pluginResult)) exclusive=\(hex(raw.exclusiveResult)) command=\(hex(raw.commandResult)) status=\(raw.taskStatus)"
        )
    }

    private func hex(_ value: Int32) -> String {
        String(format: "0x%08X", UInt32(bitPattern: value))
    }

    private func run(cdb: [UInt8]) -> KMLinkSCSICommandResult {
        var raw = KMLinkSCSICommandResult()
        guard let session else {
            return raw
        }
        cdb.withUnsafeBufferPointer { buffer in
            KMLinkSCSISessionCommand(
                session,
                buffer.baseAddress,
                UInt8(cdb.count),
                nil,
                0,
                0,
                0,
                &raw
            )
        }
        return raw
    }

    private func openSessionIfNeeded() -> HIDForwardResult {
        if session != nil {
            return HIDForwardResult(succeeded: true, summary: "session-ready")
        }

        guard transportLock.acquire() else {
            return HIDForwardResult(succeeded: false, summary: "transport-busy")
        }

        var openResult = openSession()
        if openResult.succeeded {
            return HIDForwardResult(succeeded: true, summary: "session-opened")
        }

        var preparation = ""
        if openResult.raw.exclusiveResult != 0 {
            preparation = Self.unmountMediaIfPresent()
            openResult = openSession()
            if openResult.succeeded {
                return HIDForwardResult(succeeded: true, summary: "session-opened-after-unmount")
            }
        }

        let prefix = preparation.isEmpty ? "" : "\(preparation); "
        let raw = openResult.raw
        transportLock.release()
        return HIDForwardResult(
            succeeded: false,
            summary: "\(prefix)session result=\(raw.result) plugin=\(hex(raw.pluginResult)) exclusive=\(hex(raw.exclusiveResult))"
        )
    }

    private func openSession() -> (succeeded: Bool, raw: KMLinkSCSICommandResult) {
        var raw = KMLinkSCSICommandResult()
        guard let service = Self.findCompactDiscService() else {
            return (false, raw)
        }
        defer { IOObjectRelease(service) }

        session = KMLinkSCSISessionOpen(service, &raw)
        return (session != nil, raw)
    }

    private func closeSession() {
        if let session {
            KMLinkSCSISessionClose(session)
            self.session = nil
        }
        transportLock.release()
    }

    private func makePacket(event: CGEvent, type: CGEventType) -> (kind: HIDForwardKind, report: [UInt8])? {
        switch type {
        case .keyDown:
            return makeKeyboardPacket(event: event, isDown: true)
        case .keyUp:
            return makeKeyboardPacket(event: event, isDown: false)
        case .flagsChanged:
            modifierByte = Self.modifierByte(from: event.flags)
            return (kind: .keyboard, report: keyboardReport(activeKey: nil))
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            return (kind: .mouse, report: mouseButtonReport(type: type))
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return makeMouseMovePacket(event: event)
        case .scrollWheel:
            return makeScrollPacket(event: event)
        default:
            return nil
        }
    }

    private func makeKeyboardPacket(event: CGEvent, isDown: Bool) -> (kind: HIDForwardKind, report: [UInt8])? {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard let usage = Self.usbUsage(for: keyCode) else {
            return nil
        }

        modifierByte = Self.modifierByte(from: event.flags)
        if isDown {
            pressedKeys.insert(usage)
        } else {
            pressedKeys.remove(usage)
        }

        return (kind: .keyboard, report: keyboardReport(activeKey: usage))
    }

    private func keyboardReport(activeKey: UInt8?) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: 12)
        report[0] = modifierByte
        let keys = Array(pressedKeys.prefix(6))
        for (index, key) in keys.enumerated() {
            report[index + 2] = key
        }
        if keys.isEmpty, let activeKey {
            report[2] = activeKey
        }
        return report
    }

    private func mouseButtonReport(type: CGEventType) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: 12)
        switch type {
        case .leftMouseDown:
            report[0] = 0x01
        case .rightMouseDown:
            report[0] = 0x02
        case .otherMouseDown:
            report[0] = 0x04
        default:
            report[0] = 0x00
        }
        return report
    }

    private func makeMouseMovePacket(event: CGEvent) -> (kind: HIDForwardKind, report: [UInt8])? {
        let now = Date()
        guard now.timeIntervalSince(lastMouseSend) > 0.012 else {
            return nil
        }
        lastMouseSend = now

        let dx = Int16(clamping: event.getIntegerValueField(.mouseEventDeltaX))
        let dy = Int16(clamping: event.getIntegerValueField(.mouseEventDeltaY))
        if dx == 0, dy == 0 {
            return nil
        }

        var report = [UInt8](repeating: 0, count: 12)
        report[0] = 0x01
        report[1] = UInt8(truncatingIfNeeded: dx)
        report[2] = UInt8(truncatingIfNeeded: dx >> 8)
        report[3] = UInt8(truncatingIfNeeded: dy)
        report[4] = UInt8(truncatingIfNeeded: dy >> 8)
        return (kind: .mouse, report: report)
    }

    private func makeScrollPacket(event: CGEvent) -> (kind: HIDForwardKind, report: [UInt8])? {
        let y = Int8(clamping: event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        let x = Int8(clamping: event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        guard x != 0 || y != 0 else {
            return nil
        }

        var report = [UInt8](repeating: 0, count: 12)
        report[3] = UInt8(bitPattern: y)
        report[4] = UInt8(bitPattern: x)
        return (kind: .mouse, report: report)
    }

    private static func findCompactDiscService() -> io_service_t? {
        guard let usbService = findUSBDevice() else {
            return nil
        }
        defer { IOObjectRelease(usbService) }

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

        visit(usbService, depth: 0)
        return found
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

    private static func unmountMediaIfPresent() -> String {
        guard let usbService = findUSBDevice() else {
            return "no-usb-device-for-unmount"
        }
        defer { IOObjectRelease(usbService) }
        return SCSIMediaPreparer.unmountMediaIfPresent(from: usbService)
    }

    private static func modifierByte(from flags: CGEventFlags) -> UInt8 {
        var result: UInt8 = 0
        if flags.contains(.maskControl) { result |= 0x01 }
        if flags.contains(.maskShift) { result |= 0x02 }
        if flags.contains(.maskAlternate) { result |= 0x04 }
        if flags.contains(.maskCommand) { result |= 0x08 }
        return result
    }

    private static func usbUsage(for keyCode: UInt16) -> UInt8? {
        keyMap[keyCode]
    }

    private static func asciiKey(for character: Character) -> (usage: UInt8, modifier: UInt8)? {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            return nil
        }

        let value = scalar.value
        if value >= 65 && value <= 90 {
            return (UInt8(value - 65 + 0x04), 0x02)
        }
        if value >= 97 && value <= 122 {
            return (UInt8(value - 97 + 0x04), 0)
        }
        if value >= 49 && value <= 57 {
            return (UInt8(value - 49 + 0x1E), 0)
        }

        switch character {
        case "0": return (0x27, 0)
        case " ": return (0x2C, 0)
        case "\n", "\r": return (0x28, 0)
        case "-": return (0x2D, 0)
        case "_": return (0x2D, 0x02)
        case "=": return (0x2E, 0)
        case "+": return (0x2E, 0x02)
        case "[": return (0x2F, 0)
        case "{": return (0x2F, 0x02)
        case "]": return (0x30, 0)
        case "}": return (0x30, 0x02)
        case "\\": return (0x31, 0)
        case "|": return (0x31, 0x02)
        case ";": return (0x33, 0)
        case ":": return (0x33, 0x02)
        case "'": return (0x34, 0)
        case "\"": return (0x34, 0x02)
        case "`": return (0x35, 0)
        case "~": return (0x35, 0x02)
        case ",": return (0x36, 0)
        case "<": return (0x36, 0x02)
        case ".": return (0x37, 0)
        case ">": return (0x37, 0x02)
        case "/": return (0x38, 0)
        case "?": return (0x38, 0x02)
        case "!": return (0x1E, 0x02)
        case "@": return (0x1F, 0x02)
        case "#": return (0x20, 0x02)
        case "$": return (0x21, 0x02)
        case "%": return (0x22, 0x02)
        case "^": return (0x23, 0x02)
        case "&": return (0x24, 0x02)
        case "*": return (0x25, 0x02)
        case "(": return (0x26, 0x02)
        case ")": return (0x27, 0x02)
        default: return nil
        }
    }

    private static let keyMap: [UInt16: UInt8] = [
        0: 0x04, 1: 0x16, 2: 0x07, 3: 0x09, 4: 0x0B, 5: 0x0A, 6: 0x1D, 7: 0x1B,
        8: 0x06, 9: 0x19, 11: 0x05, 12: 0x14, 13: 0x1A, 14: 0x08, 15: 0x15,
        16: 0x1C, 17: 0x17, 18: 0x1E, 19: 0x1F, 20: 0x20, 21: 0x21, 22: 0x22,
        23: 0x23, 24: 0x2E, 25: 0x26, 26: 0x24, 27: 0x2D, 28: 0x25, 29: 0x27,
        30: 0x30, 31: 0x12, 32: 0x18, 33: 0x2F, 34: 0x0C, 35: 0x13, 36: 0x28,
        37: 0x0F, 38: 0x0D, 39: 0x34, 40: 0x0E, 41: 0x33, 42: 0x31, 43: 0x36,
        44: 0x38, 45: 0x11, 46: 0x10, 47: 0x37, 48: 0x2B, 49: 0x2C, 50: 0x35,
        51: 0x2A, 53: 0x29, 65: 0x63, 67: 0x55, 69: 0x57, 71: 0x5F, 75: 0x56,
        76: 0x58, 78: 0x56, 81: 0x57, 82: 0x62, 83: 0x59, 84: 0x5A, 85: 0x5B,
        86: 0x5C, 87: 0x5D, 88: 0x5E, 89: 0x5F, 91: 0x60, 92: 0x61, 96: 0x3E,
        97: 0x3F, 98: 0x40, 99: 0x3C, 100: 0x41, 101: 0x42, 103: 0x44, 105: 0x46,
        106: 0x47, 107: 0x48, 109: 0x45, 111: 0x4A, 113: 0x4D, 114: 0x4B,
        115: 0x4A, 116: 0x4C, 117: 0x4C, 118: 0x49, 119: 0x4D, 120: 0x43,
        121: 0x51, 122: 0x3A, 123: 0x50, 124: 0x4F, 125: 0x51, 126: 0x52
    ]
}
