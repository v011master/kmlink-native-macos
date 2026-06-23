import DiskArbitration
import Foundation
import IOKit

enum SCSIMediaPreparer {
    static func unmountMediaIfPresent(from root: io_registry_entry_t) -> String {
        let bsdNames = mediaBSDNames(from: root)
        guard !bsdNames.isEmpty else {
            return "no mounted media"
        }

        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            return bsdNames
                .map { bsdName in
                    let result = runDiskutilUnmount(bsdName: bsdName)
                    if result.succeeded {
                        return "diskutil-unmounted \(bsdName)"
                    }
                    return "failed to create DiskArbitration session for \(bsdName); diskutil=\(result.status) \(result.output)"
                }
                .joined(separator: "; ")
        }
        DASessionScheduleWithRunLoop(session, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        defer {
            DASessionUnscheduleFromRunLoop(session, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        }

        var outcomes: [String] = []
        for bsdName in bsdNames {
            outcomes.append(unmount(bsdName: bsdName, session: session))
        }
        return outcomes.joined(separator: "; ")
    }

    private static func unmount(bsdName: String, session: DASession) -> String {
        let bsdPath = "/dev/\(bsdName)"
        guard let disk = bsdPath.withCString({ DADiskCreateFromBSDName(kCFAllocatorDefault, session, $0) }) else {
            return "failed to create DADisk for \(bsdPath)"
        }

        let defaultResult = unmount(disk: disk, options: DADiskUnmountOptions(kDADiskUnmountOptionDefault))
        if defaultResult == 0 {
            return "unmounted \(bsdName)"
        }

        let forceResult = unmount(disk: disk, options: DADiskUnmountOptions(kDADiskUnmountOptionForce))
        if forceResult == 0 {
            return "force-unmounted \(bsdName)"
        }

        let diskutilResult = runDiskutilUnmount(bsdName: bsdName)
        if diskutilResult.succeeded {
            return "diskutil-unmounted \(bsdName)"
        }

        return String(
            format: "unmount %@ failed default=0x%08X force=0x%08X diskutil=%d %@",
            bsdName,
            UInt32(bitPattern: defaultResult),
            UInt32(bitPattern: forceResult),
            diskutilResult.status,
            diskutilResult.output
        )
    }

    private static func unmount(disk: DADisk, options: DADiskUnmountOptions) -> Int32 {
        let context = MediaUnmountContext()
        DADiskUnmount(
            disk,
            options,
            { _, dissenter, rawContext in
                guard let rawContext else {
                    return
                }
                let context = Unmanaged<MediaUnmountContext>.fromOpaque(rawContext).takeUnretainedValue()
                context.status = dissenter.map { DADissenterGetStatus($0) } ?? 0
                context.done = true
            },
            Unmanaged.passUnretained(context).toOpaque()
        )

        let deadline = Date().addingTimeInterval(2.0)
        while !context.done && Date() < deadline {
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.05, false)
        }

        return context.done ? context.status : -1
    }

    private static func mediaBSDNames(from root: io_registry_entry_t) -> [String] {
        var found: [(name: String, score: Int)] = []
        var seen = Set<String>()

        func visit(_ node: io_registry_entry_t, depth: Int) {
            guard depth <= 8 else {
                return
            }

            var iterator: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(node, kIOServicePlane, &iterator) == KERN_SUCCESS else {
                return
            }
            defer { IOObjectRelease(iterator) }

            while true {
                let child = IOIteratorNext(iterator)
                if child == 0 {
                    break
                }
                defer { IOObjectRelease(child) }

                let node = RegistryNode.make(child)
                if (node.ioClass == "IOCDMedia" || node.ioClass == "IOMedia"),
                   let bsdName = node.properties["BSD Name"],
                   !seen.contains(bsdName) {
                    seen.insert(bsdName)
                    let isCD = node.ioClass == "IOCDMedia" || node.properties["Content"]?.contains("CD") == true
                    let isLeaf = node.properties["Leaf"] == "Yes"
                    let score = (isCD ? 0 : 10) + (isLeaf ? 0 : 1)
                    found.append((bsdName, score))
                }
                visit(child, depth: depth + 1)
            }
        }

        visit(root, depth: 0)
        return found.sorted { left, right in
            if left.score == right.score {
                return left.name < right.name
            }
            return left.score < right.score
        }.map(\.name)
    }

    private static func runDiskutilUnmount(bsdName: String) -> (succeeded: Bool, status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["unmountDisk", "force", "/dev/\(bsdName)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (false, -1, error.localizedDescription)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            ?? ""
        return (process.terminationStatus == 0, process.terminationStatus, output)
    }
}

private final class MediaUnmountContext {
    var done = false
    var status: Int32 = 0
}
