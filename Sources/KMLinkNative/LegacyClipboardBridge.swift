import Darwin
import AppKit
import Foundation

struct LegacyClipboardSendResult {
    let succeeded: Bool
    let summary: String
    let logPath: String?
}

struct LegacyBridgeSessionResult {
    let initialized: Bool
    let tapEnabled: Bool
    let clipboardEnabled: Bool
    let connected: Bool
    let remoteAppOff: Bool
    let logPath: String?
    let summary: String
}

struct ClipboardWriteProbe {
    let pbcopyStatus: Int32?
    let appleScriptStatus: Int32?
    let observedClipboard: String?
}

struct LegacyClipboardReceiveResult {
    let succeeded: Bool
    let summary: String
    let text: String?
    let logPath: String?
}

enum LegacyClipboardBridge {
    private static let archPath = "/usr/bin/arch"
    private static var legacyAppPath: String {
        if let configured = ProcessInfo.processInfo.environment["KMLINK_LEGACY_APP_PATH"],
           !configured.isEmpty {
            return NSString(string: configured).expandingTildeInPath
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/MacKMLinkFull/MacKMLink.app")
            .path
    }
    private static var appPath: String {
        URL(fileURLWithPath: legacyAppPath)
            .appendingPathComponent("Contents/MacOS/MacKMLink")
            .path
    }
    private static var demonPath: String {
        URL(fileURLWithPath: legacyAppPath)
            .appendingPathComponent("Contents/PlugIns/GoBridgeDemon.app/Contents/MacOS/GoBridgeDemon")
            .path
    }
    private static var legacyLaunchAgentPath: String? {
        guard let configured = ProcessInfo.processInfo.environment["KMLINK_LEGACY_LAUNCH_AGENT_PATH"],
              !configured.isEmpty else {
            return nil
        }
        return NSString(string: configured).expandingTildeInPath
    }

    static func sendText(_ text: String) -> LegacyClipboardSendResult {
        stopLegacyProcesses()

        var attemptResults: [LegacyClipboardSendResult] = []
        for attempt in 1...2 {
            let result = sendTextOnce(text, attempt: attempt)
            attemptResults.append(result)
            if result.succeeded {
                if attempt == 1 {
                    return result
                }
                return LegacyClipboardSendResult(
                    succeeded: true,
                    summary: "legacy clipboard bridge recovered on retry \(attempt); \(result.summary)",
                    logPath: result.logPath
                )
            }
            usleep(700_000)
            stopLegacyProcesses()
        }

        let last = attemptResults.last ?? LegacyClipboardSendResult(succeeded: false, summary: "legacy clipboard bridge no-attempts", logPath: nil)
        return LegacyClipboardSendResult(
            succeeded: false,
            summary: "legacy clipboard bridge failed after \(attemptResults.count) attempts; \(last.summary)",
            logPath: last.logPath
        )
    }

    static func probeRemoteSession() -> LegacyBridgeSessionResult {
        stopLegacyProcesses()

        let result = runHostSession(textToSend: nil, attempt: 1)
        stopLegacyProcesses()
        return LegacyBridgeSessionResult(
            initialized: result.initialized,
            tapEnabled: result.tapEnabled,
            clipboardEnabled: result.clipboardEnabled,
            connected: result.connected,
            remoteAppOff: result.remoteAppOff,
            logPath: result.logPath,
            summary: result.summary
        )
    }

    static func receiveText(
        waitSeconds: TimeInterval = 18.0,
        expectedText: String? = nil,
        progress: ((String) -> Void)? = nil
    ) -> LegacyClipboardReceiveResult {
        stopLegacyProcesses()

        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: archPath) else {
            return LegacyClipboardReceiveResult(succeeded: false, summary: "legacy clipboard receive missing arch", text: nil, logPath: nil)
        }
        guard fileManager.isExecutableFile(atPath: appPath) else {
            return LegacyClipboardReceiveResult(succeeded: false, summary: "legacy clipboard receive missing MacKMLink host", text: nil, logPath: nil)
        }

        let mediaPreparation = prepareLegacyHostMedia()
        let initialChangeCount = NSPasteboard.general.changeCount
        let initialText = ClipboardMonitor.currentText()

        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: archPath)
        process.arguments = ["-x86_64", appPath]
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let outputLock = NSLock()
        var output = ""
        let connectedSemaphore = DispatchSemaphore(value: 0)
        var connectedSeen = false

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }
            let chunk = String(data: data, encoding: .utf8)
                ?? String(decoding: data, as: UTF8.self)
            outputLock.lock()
            output.append(chunk)
            if !connectedSeen,
               output.contains("Client commandID: A2")
                || output.contains("did login to remote")
                || output.contains("got REMOTE_APP_ON") {
                connectedSeen = true
                connectedSemaphore.signal()
            }
            outputLock.unlock()
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            return LegacyClipboardReceiveResult(
                succeeded: false,
                summary: "legacy clipboard receive launch failed: \(error.localizedDescription)",
                text: nil,
                logPath: nil
            )
        }

        let connectedWait = connectedSemaphore.wait(timeout: .now() + .seconds(12)) == .success
        outputLock.lock()
        let readyOutput = output
        let ready =
            connectedWait
            || readyOutput.contains("Client commandID: A2")
            || readyOutput.contains("did login to remote")
            || readyOutput.contains("got REMOTE_APP_ON")
        outputLock.unlock()
        progress?("clipboard.receive.ready: \(ready)")
        progress?("clipboard.receive.copyNow: \(ready)")
        progress?("clipboard.receive.waitSeconds: \(Int(waitSeconds.rounded()))")

        let deadline = Date().addingTimeInterval(waitSeconds)
        var receivedText: String?
        var receivedReason = "none"
        var finalChangeCount = initialChangeCount
        var changeEvents: [String] = []
        while Date() < deadline {
            let currentChangeCount = NSPasteboard.general.changeCount
            if currentChangeCount != finalChangeCount {
                finalChangeCount = currentChangeCount
                let currentText = ClipboardMonitor.currentText()
                changeEvents.append(
                    "count=\(currentChangeCount),text=\(currentText.map { ClipboardMonitor.preview($0, limit: 36) } ?? "nil")"
                )
                if let currentText, !currentText.isEmpty {
                    receivedText = currentText
                    if expectedText == nil || currentText == expectedText {
                        receivedReason = currentText == initialText ? "pasteboard-change-same-text" : "pasteboard-change-new-text"
                        break
                    }
                }
            }
            usleep(300_000)
        }

        if process.isRunning {
            process.terminate()
            waitForExit(process, timeoutSeconds: 2)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            waitForExit(process, timeoutSeconds: 2)
        }
        outputPipe.fileHandleForReading.readabilityHandler = nil

        outputLock.lock()
        let fullOutput = output
        outputLock.unlock()

        let logPath = writeLog(kind: "legacy-clipboard-receive", text: receivedText ?? "", output: fullOutput)
        let connected =
            fullOutput.contains("Client commandID: A2")
            || fullOutput.contains("did login to remote")
            || fullOutput.contains("got REMOTE_APP_ON")
        let sawTransferClipboard = fullOutput.contains("Cmd_Transfer_Clipboard")
        let sawPasteboardUpdate =
            fullOutput.contains("addFromUPipeMsg(): Found incoming clipboard data")
            || fullOutput.contains("addFromUPipeMsg(): Found incoming clipboard format")
        let sawClipboardDiscard = fullOutput.contains("Clipboard off, data discard")
        let expectedMatched = expectedText.map { receivedText == $0 } ?? false
        let succeeded = {
            guard let receivedText, !receivedText.isEmpty else {
                return false
            }
            if let expectedText {
                return receivedText == expectedText
            }
            return true
        }()
        let finalReason = succeeded
            ? receivedReason
            : (receivedText == nil ? "no-text-change" : "expected-mismatch")
        let eventSummary = changeEvents.isEmpty
            ? "none"
            : changeEvents.prefix(4).joined(separator: " / ")
        let summary =
            "legacy clipboard receive connected=\(connected) changed=\(finalChangeCount != initialChangeCount) changeCount=\(initialChangeCount)->\(finalChangeCount) textObserved=\(receivedText != nil) expectedMatched=\(expectedMatched) reason=\(finalReason) sawTransferClipboard=\(sawTransferClipboard) sawPasteboardUpdate=\(sawPasteboardUpdate) sawClipboardDiscard=\(sawClipboardDiscard) events=\(eventSummary) \(mediaPreparation) log=\(logPath ?? "none") \(summarizeTail(fullOutput))"
        stopLegacyProcesses()
        return LegacyClipboardReceiveResult(
            succeeded: succeeded,
            summary: summary,
            text: succeeded ? receivedText : nil,
            logPath: logPath
        )
    }

    private static func sendTextOnce(_ text: String, attempt: Int) -> LegacyClipboardSendResult {
        sendTextViaLegacyShellScenario(text, attempt: attempt)
    }

    private static func runHostSession(textToSend: String?, attempt: Int) -> HostSessionResult {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: archPath) else {
            return HostSessionResult.failure(summary: "legacy clipboard bridge missing arch")
        }
        guard fileManager.isExecutableFile(atPath: appPath) else {
            return HostSessionResult.failure(summary: "legacy clipboard bridge missing MacKMLink host")
        }

        let mediaPreparation = prepareLegacyHostMedia()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: archPath)
        process.arguments = ["-x86_64", appPath]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let outputLock = NSLock()
        var output = ""
        let initializedSemaphore = DispatchSemaphore(value: 0)
        let tapEnabledSemaphore = DispatchSemaphore(value: 0)
        let clipboardEnabledSemaphore = DispatchSemaphore(value: 0)
        let connectedSemaphore = DispatchSemaphore(value: 0)
        let clipboardSentSemaphore = DispatchSemaphore(value: 0)
        var initializedSeen = false
        var tapEnabledSeen = false
        var clipboardEnabledSeen = false
        var connectedSeen = false
        var clipboardSentSeen = false
        var remoteAppOffSeen = false

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }
            let chunk = String(data: data, encoding: .utf8)
                ?? String(decoding: data, as: UTF8.self)
            outputLock.lock()
            output.append(chunk)
            if !initializedSeen, output.contains("Device Initialized successfully!!!") {
                initializedSeen = true
                initializedSemaphore.signal()
            }
            if !tapEnabledSeen, output.contains("CGEvent keyboard tap enabled!!!") {
                tapEnabledSeen = true
                tapEnabledSemaphore.signal()
            }
            if !clipboardEnabledSeen, output.contains("ClipboardHandler: Get notice of clipboard is on...") {
                clipboardEnabledSeen = true
                clipboardEnabledSemaphore.signal()
            }
            if !connectedSeen,
               output.contains("Send command: A2")
                || output.contains("Client commandID: A2")
                || output.contains("remote has login")
                || output.contains("did login to remote")
                || output.contains("got REMOTE_APP_ON") {
                connectedSeen = true
                connectedSemaphore.signal()
            }
            if !clipboardSentSeen, output.contains("Send command: 39") {
                clipboardSentSeen = true
                clipboardSentSemaphore.signal()
            }
            if !remoteAppOffSeen, output.contains("got REMOTE_APP_OFF") {
                remoteAppOffSeen = true
            }
            outputLock.unlock()
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            return HostSessionResult.failure(summary: "legacy clipboard bridge launch failed: \(error.localizedDescription)")
        }

        var clipboardWriteProbe: ClipboardWriteProbe?
        let initialized = initializedSemaphore.wait(timeout: .now() + .seconds(6)) == .success
        let tapEnabled = tapEnabledSemaphore.wait(timeout: .now() + .seconds(4)) == .success
        let clipboardEnabled = clipboardEnabledSemaphore.wait(timeout: .now() + .seconds(12)) == .success
        let connected = connectedSemaphore.wait(timeout: .now() + .seconds(12)) == .success
        if initialized {
            if let textToSend, tapEnabled && clipboardEnabled && connected {
                usleep(2_500_000)
                clipboardWriteProbe = writeClipboardText(textToSend)
            } else if textToSend != nil, !tapEnabled {
                usleep(1_000_000)
            } else if textToSend != nil, !clipboardEnabled || !connected {
                usleep(1_000_000)
            } else {
                usleep(1_000_000)
            }
            _ = clipboardSentSemaphore.wait(timeout: .now() + .seconds(8))
            usleep(600_000)
        } else {
            usleep(1_000_000)
        }

        if process.isRunning {
            process.terminate()
            waitForExit(process, timeoutSeconds: 2)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            waitForExit(process, timeoutSeconds: 2)
        }

        outputPipe.fileHandleForReading.readabilityHandler = nil

        outputLock.lock()
        let fullOutput = output
        outputLock.unlock()

        let logPath = writeLog(text: textToSend ?? "", output: fullOutput)
        let observedInitialized = fullOutput.contains("Device Initialized successfully!!!")
        let observedTapEnabled = fullOutput.contains("CGEvent keyboard tap enabled!!!")
        let observedClipboardEnabled = fullOutput.contains("ClipboardHandler: Get notice of clipboard is on...")
        let observedConnected =
            fullOutput.contains("Send command: A2")
            || fullOutput.contains("Client commandID: A2")
            || fullOutput.contains("remote has login")
            || fullOutput.contains("did login to remote")
            || fullOutput.contains("got REMOTE_APP_ON")
        let observedRemoteAppOff = fullOutput.contains("got REMOTE_APP_OFF")
        let tail = summarizeTail(fullOutput)
        let sawClipboardCommand = fullOutput.contains("Send command: 39")
        let status = process.terminationStatus
        let textDescription = textToSend.map { "\($0.count) chars" } ?? "probe-only"
        let writeProbeSummary: String
        if let clipboardWriteProbe {
            writeProbeSummary = "writeProbe=pbcopy:\(clipboardWriteProbe.pbcopyStatus.map(String.init) ?? "nil"),osa:\(clipboardWriteProbe.appleScriptStatus.map(String.init) ?? "nil"),pbpaste:\"\(ClipboardMonitor.preview(clipboardWriteProbe.observedClipboard ?? "", limit: 40))\""
        } else {
            writeProbeSummary = "writeProbe=none"
        }
        let summary = observedInitialized
            ? "legacy clipboard bridge attempt=\(attempt) sent \(textDescription) exit=\(status) tapEnabled=\(observedTapEnabled) clipboardEnabled=\(observedClipboardEnabled) connected=\(observedConnected) remoteAppOff=\(observedRemoteAppOff) sawClipboard39=\(sawClipboardCommand) \(writeProbeSummary) \(mediaPreparation) log=\(logPath ?? "none") \(tail)"
            : "legacy clipboard bridge attempt=\(attempt) not-ready exit=\(status) \(mediaPreparation) log=\(logPath ?? "none") \(tail)"
        return HostSessionResult(
            initialized: observedInitialized,
            tapEnabled: observedTapEnabled,
            clipboardEnabled: observedClipboardEnabled,
            connected: observedConnected,
            remoteAppOff: observedRemoteAppOff,
            sawClipboardCommand: sawClipboardCommand,
            succeeded: observedInitialized && observedTapEnabled && observedClipboardEnabled && observedConnected && sawClipboardCommand,
            summary: summary,
            logPath: logPath
        )
    }

    private static func summarizeTail(_ text: String) -> String {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .suffix(6)
            .map(String.init)
        if lines.isEmpty {
            return "logs=none"
        }
        return "logs=" + lines.joined(separator: " | ")
    }

    private static func waitForExit(_ process: Process, timeoutSeconds: Int) {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while process.isRunning, Date() < deadline {
            usleep(100_000)
        }
    }

    private static func stopLegacyProcesses() {
        if let legacyLaunchAgentPath {
            _ = shell("/bin/launchctl", ["bootout", "gui/\(getuid())", legacyLaunchAgentPath])
        }
        _ = shell("/usr/bin/pkill", ["-f", demonPath])
        _ = shell("/usr/bin/pkill", ["-f", legacyAppPath])
        usleep(300_000)
    }

    private static func prepareLegacyHostMedia() -> String {
        if FileManager.default.fileExists(atPath: "/Volumes/MacKMLink") {
            return "media=mounted"
        }

        guard let identifier = macKMLinkDiskIdentifier() else {
            return "media=not-present"
        }

        let status = shell("/usr/sbin/diskutil", ["mount", identifier])
        usleep(500_000)
        let mounted = FileManager.default.fileExists(atPath: "/Volumes/MacKMLink")
        return "media=mount-\(identifier):\(status),mounted=\(mounted)"
    }

    @discardableResult
    private static func shell(_ executable: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    private static func shellOutput(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
                ?? String(decoding: data, as: UTF8.self)
        } catch {
            return ""
        }
    }

    private static func macKMLinkDiskIdentifier() -> String? {
        shellOutput("/usr/sbin/diskutil", ["list"])
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                guard line.contains("MacKMLink") else {
                    return nil
                }
                return line.split(separator: " ").last.map(String.init)
            }
            .first
    }

    private static func sendTextViaLegacyShellScenario(_ text: String, attempt: Int) -> LegacyClipboardSendResult {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: archPath) else {
            return LegacyClipboardSendResult(succeeded: false, summary: "legacy clipboard bridge missing arch", logPath: nil)
        }
        guard fileManager.isExecutableFile(atPath: appPath) else {
            return LegacyClipboardSendResult(succeeded: false, summary: "legacy clipboard bridge missing MacKMLink host", logPath: nil)
        }

        let logDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/KMLinkNative", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        } catch {
            return LegacyClipboardSendResult(succeeded: false, summary: "legacy clipboard bridge log dir failed: \(error.localizedDescription)", logPath: nil)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let logPath = logDirectory
            .appendingPathComponent("legacy-clipboard-send-\(timestamp).log")
            .path

        let script = """
        set -euo pipefail
        legacy_app="$KMLINK_NATIVE_LEGACY_APP"
        legacy_exe="$legacy_app/Contents/MacOS/MacKMLink"
        legacy_demon="$legacy_app/Contents/PlugIns/GoBridgeDemon.app/Contents/MacOS/GoBridgeDemon"
        if [[ -n "${KMLINK_NATIVE_LEGACY_LAUNCH_AGENT:-}" ]]; then
          launchctl bootout gui/$(id -u) "$KMLINK_NATIVE_LEGACY_LAUNCH_AGENT" 2>/dev/null || true
        fi
        pkill -f "$legacy_app" 2>/dev/null || true
        pkill -f "$legacy_demon" 2>/dev/null || true
        rm -f "$KMLINK_NATIVE_LEGACY_LOG"
        /usr/bin/arch -x86_64 "$legacy_exe" > "$KMLINK_NATIVE_LEGACY_LOG" 2>&1 &
        apppid=$!
        sleep 11
        printf %s "$KMLINK_NATIVE_CLIPBOARD_TEXT" | pbcopy
        sleep 8
        kill "$apppid" 2>/dev/null || true
        wait "$apppid" 2>/dev/null || true
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", script]
        var environment = ProcessInfo.processInfo.environment
        environment["KMLINK_NATIVE_CLIPBOARD_TEXT"] = text
        environment["KMLINK_NATIVE_LEGACY_LOG"] = logPath
        environment["KMLINK_NATIVE_LEGACY_APP"] = legacyAppPath
        environment["KMLINK_NATIVE_LEGACY_LAUNCH_AGENT"] = legacyLaunchAgentPath ?? ""
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return LegacyClipboardSendResult(
                succeeded: false,
                summary: "legacy clipboard bridge shell scenario launch failed: \(error.localizedDescription)",
                logPath: logPath
            )
        }

        let output = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        let sawClipboardCommand = output.contains("Send command: 39")
        let sawConnected =
            output.contains("Client commandID: A2")
            || output.contains("did login to remote")
            || output.contains("got REMOTE_APP_ON")
        let remoteAppOff = output.contains("got REMOTE_APP_OFF")
        let tail = summarizeTail(output)
        let summary =
            "legacy clipboard bridge attempt=\(attempt) shellScenario exit=\(process.terminationStatus) connected=\(sawConnected) remoteAppOff=\(remoteAppOff) sawClipboard39=\(sawClipboardCommand) log=\(logPath) \(tail)"
        return LegacyClipboardSendResult(
            succeeded: sawClipboardCommand,
            summary: summary,
            logPath: logPath
        )
    }

    private static func writeClipboardText(_ text: String) -> ClipboardWriteProbe {
        let pbcopyStatus = writeClipboardViaShellPBCopy(text)
        let appleScriptStatus = writeClipboardViaAppleScript(text)
        usleep(300_000)
        return ClipboardWriteProbe(
            pbcopyStatus: pbcopyStatus,
            appleScriptStatus: appleScriptStatus,
            observedClipboard: readClipboardText()
        )
    }

    private static func writeClipboardViaShellPBCopy(_ text: String) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "printf %s \"$KMLINK_NATIVE_CLIPBOARD_TEXT\" | pbcopy"]
        var environment = ProcessInfo.processInfo.environment
        environment["KMLINK_NATIVE_CLIPBOARD_TEXT"] = text
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            NSLog("KMLinkNative shell pbcopy failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func writeClipboardViaAppleScript(_ text: String) -> Int32? {
        let writeProcess = Process()
        writeProcess.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        writeProcess.arguments = ["-e", "set the clipboard to \(appleScriptStringLiteral(text))"]
        writeProcess.standardOutput = Pipe()
        writeProcess.standardError = Pipe()
        do {
            try writeProcess.run()
            writeProcess.waitUntilExit()
            return writeProcess.terminationStatus
        } catch {
            NSLog("KMLinkNative osascript clipboard write failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func readClipboardText() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pbpaste")
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            NSLog("KMLinkNative pbpaste failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func appleScriptStringLiteral(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func writeLog(kind: String = "legacy-clipboard-send", text: String, output: String) -> String? {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/KMLinkNative", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let timestamp = formatter.string(from: Date())
            let file = directory.appendingPathComponent("\(kind)-\(timestamp).log")
            let body = """
            text.chars: \(text.count)
            text.preview: \(ClipboardMonitor.preview(text, limit: 80))

            \(output)
            """
            try body.write(to: file, atomically: true, encoding: .utf8)
            return file.path
        } catch {
            NSLog("KMLinkNative legacy clipboard log failed: \(error.localizedDescription)")
            return nil
        }
    }
}

private struct HostSessionResult {
    let initialized: Bool
    let tapEnabled: Bool
    let clipboardEnabled: Bool
    let connected: Bool
    let remoteAppOff: Bool
    let sawClipboardCommand: Bool
    let succeeded: Bool
    let summary: String
    let logPath: String?

    static func failure(summary: String) -> HostSessionResult {
        HostSessionResult(
            initialized: false,
            tapEnabled: false,
            clipboardEnabled: false,
            connected: false,
            remoteAppOff: false,
            sawClipboardCommand: false,
            succeeded: false,
            summary: summary,
            logPath: nil
        )
    }
}
