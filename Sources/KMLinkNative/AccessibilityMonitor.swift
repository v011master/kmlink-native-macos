import ApplicationServices
import Foundation

final class AccessibilityMonitor {
    private(set) var isTrusted = false

    func refresh(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)
        return isTrusted
    }
}
