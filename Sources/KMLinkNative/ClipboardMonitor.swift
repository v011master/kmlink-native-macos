import AppKit
import Foundation

final class ClipboardMonitor {
    var onChange: ((String) -> Void)?

    private(set) var lastSummary = "idle"
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func poll() {
        guard pasteboard.changeCount != lastChangeCount else {
            return
        }

        lastChangeCount = pasteboard.changeCount
        lastSummary = summarizePasteboard()
        onChange?(lastSummary)
    }

    private func summarizePasteboard() -> String {
        Self.currentSummary()
    }

    static func currentSummary() -> String {
        let pasteboard = NSPasteboard.general
        if let text = pasteboard.string(forType: .string) {
            return "text \(text.count) chars \"\(preview(text))\""
        }

        let types = pasteboard.types?.map(\.rawValue).joined(separator: ", ") ?? "unknown"
        return "types \(types)"
    }

    static func currentText() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    static func setText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func preview(_ text: String, limit: Int = 28) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        if singleLine.count <= limit {
            return singleLine
        }
        return String(singleLine.prefix(limit)) + "..."
    }
}
