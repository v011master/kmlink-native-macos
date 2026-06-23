import ApplicationServices
import Foundation

enum InputForwardingMode {
    case watching
    case mirrored
    case remoteOnly

    var forwardsEvents: Bool {
        self != .watching
    }

    var suppressesLocalEvents: Bool {
        self == .remoteOnly
    }

    var label: String {
        switch self {
        case .watching:
            return "watching"
        case .mirrored:
            return "mirroring"
        case .remoteOnly:
            return "remote-only"
        }
    }

    var tapOptions: CGEventTapOptions {
        suppressesLocalEvents ? .defaultTap : .listenOnly
    }
}

final class EventTapMonitor {
    var onChange: (() -> Void)?
    var onEvent: ((CGEvent, CGEventType) -> Void)?
    var mode: InputForwardingMode = .watching {
        didSet {
            guard oldValue != mode else {
                return
            }

            let wasRunning = isRunning
            if wasRunning {
                stop()
                startIfTrusted()
            }
            onChange?()
        }
    }

    private(set) var isRunning = false
    private(set) var keyEventCount = 0
    private(set) var mouseEventCount = 0
    private(set) var lastEvent = "none"

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var statusLine: String {
        guard isRunning else {
            return "Input tap: stopped"
        }

        return "Input tap: \(mode.label) keys=\(keyEventCount) mouse=\(mouseEventCount) last=\(lastEvent)"
    }

    func startIfTrusted() {
        guard AXIsProcessTrusted() else {
            stop()
            return
        }

        guard tap == nil else {
            return
        }

        let eventMask = Self.eventTypes.reduce(CGEventMask(0)) { mask, type in
            mask | (CGEventMask(1) << CGEventMask(type.rawValue))
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let nextTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: mode.tapOptions,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: refcon
        ) else {
            isRunning = false
            lastEvent = "failed-to-create"
            onChange?()
            return
        }

        tap = nextTap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, nextTap, 0)

        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }

        CGEvent.tapEnable(tap: nextTap, enable: true)
        isRunning = true
        lastEvent = "started"
        onChange?()
    }

    func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }

        source = nil
        tap = nil
        isRunning = false
        lastEvent = "stopped"
        onChange?()
    }

    fileprivate func record(event: CGEvent, type: CGEventType) -> Bool {
        if shouldExitRemoteOnly(event: event, type: type) {
            DispatchQueue.main.async { [weak self] in
                self?.mode = .watching
            }
            return false
        }

        switch type {
        case .keyDown, .keyUp, .flagsChanged:
            keyEventCount += 1
        default:
            mouseEventCount += 1
        }

        lastEvent = String(describing: type)
        if (keyEventCount + mouseEventCount) % 20 == 0 {
            DispatchQueue.main.async { [weak self] in
                self?.onChange?()
            }
        }

        if mode.forwardsEvents {
            onEvent?(event, type)
        }

        return mode.suppressesLocalEvents
    }

    private func shouldExitRemoteOnly(event: CGEvent, type: CGEventType) -> Bool {
        guard mode == .remoteOnly, type == .keyDown else {
            return false
        }

        let flags = event.flags
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        return keyCode == 40
            && flags.contains(.maskControl)
            && flags.contains(.maskAlternate)
            && flags.contains(.maskCommand)
    }

    private static let eventTypes: [CGEventType] = [
        .keyDown,
        .keyUp,
        .flagsChanged,
        .leftMouseDown,
        .leftMouseUp,
        .rightMouseDown,
        .rightMouseUp,
        .otherMouseDown,
        .otherMouseUp,
        .mouseMoved,
        .leftMouseDragged,
        .rightMouseDragged,
        .otherMouseDragged,
        .scrollWheel
    ]
}

private let eventTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    if let refcon {
        let monitor = Unmanaged<EventTapMonitor>.fromOpaque(refcon).takeUnretainedValue()
        if monitor.record(event: event, type: type) {
            return nil
        }
    }

    return Unmanaged.passUnretained(event)
}
