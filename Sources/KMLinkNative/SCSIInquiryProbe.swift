import Foundation
import IOKit
import KMLinkNativeCSCSI

struct SCSIInquirySnapshot {
    let attempts: [SCSIInquiryAttempt]

    var best: SCSIInquiryAttempt? {
        attempts.first { $0.succeeded }
    }

    var statusLine: String {
        if let best {
            let identity = [best.vendor, best.product, best.revision]
                .compactMap { value in value.isEmpty ? nil : value }
                .joined(separator: " ")
            return identity.isEmpty ? "SCSI: INQUIRY ok" : "SCSI: \(identity)"
        }

        if attempts.isEmpty {
            return "SCSI: no connectable service"
        }

        return "SCSI: INQUIRY failed on \(attempts.count) candidate(s)"
    }

    var diagnostics: String {
        var lines = ["transport.scsiInquiry: \(statusLine)"]
        for attempt in attempts {
            lines.append("  - \(attempt.diagnosticLine)")
        }
        return lines.joined(separator: "\n")
    }

    static let empty = SCSIInquirySnapshot(attempts: [])
}

struct SCSIInquiryAttempt {
    let service: RegistryNode
    let result: Int32
    let pluginResult: Int32
    let queryResult: Int32
    let exclusiveResult: Int32
    let commandResult: Int32
    let serviceResponse: UInt32
    let taskStatus: UInt32
    let bytesTransferred: UInt64
    let method: String
    let vendor: String
    let product: String
    let revision: String
    let message: String
    let hexPrefix: String

    var succeeded: Bool {
        result == 0
    }

    var diagnosticLine: String {
        let identity = [vendor, product, revision]
            .compactMap { value in value.isEmpty ? nil : value }
            .joined(separator: " ")
        let suffix = identity.isEmpty ? "" : " identity=\(identity)"
        return "\(service.ioClass) method=\(method) result=\(result) plugin=\(hex(pluginResult)) query=\(queryResult) exclusive=\(hex(exclusiveResult)) command=\(hex(commandResult)) response=\(serviceResponse) status=\(taskStatus) bytes=\(bytesTransferred)\(suffix) data=\(hexPrefix) message=\(message)"
    }

    private func hex(_ value: Int32) -> String {
        String(format: "0x%08X", UInt32(bitPattern: value))
    }
}

enum SCSIInquiryProbe {
    static func probe(from root: io_registry_entry_t) -> SCSIInquirySnapshot {
        var attempts: [SCSIInquiryAttempt] = []
        var foundSuccess = false

        visitDescendants(from: root, maxDepth: 8) { service in
            guard !foundSuccess, isProbeCandidate(service) else {
                return
            }

            let node = RegistryNode.make(service)
            var raw = KMLinkSCSIInquiryResult()
            KMLinkSCSIInquiry(service, &raw)
            let attempt = SCSIInquiryAttempt(raw: raw, service: node)
            attempts.append(attempt)
            foundSuccess = attempt.succeeded
        }

        return SCSIInquirySnapshot(attempts: attempts)
    }

    private static func visitDescendants(
        from service: io_registry_entry_t,
        maxDepth: Int,
        body: (io_registry_entry_t) -> Void
    ) {
        func visit(_ node: io_registry_entry_t, depth: Int) {
            guard depth <= maxDepth else {
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

                body(child)
                visit(child, depth: depth + 1)
            }
        }

        visit(service, depth: 0)
    }

    private static func isProbeCandidate(_ service: io_registry_entry_t) -> Bool {
        let node = RegistryNode.make(service)
        let candidateClasses = [
            "IOCompactDiscServices",
            "IOSCSIPeripheralDeviceType05",
            "SCSITaskUserClient",
            "SCSITaskUserClientIniter",
            "IOSCSILogicalUnitNub"
        ]

        if candidateClasses.contains(node.ioClass) {
            return true
        }

        return node.properties.keys.contains("SCSITaskDeviceCategory")
            || node.properties.keys.contains("SCSITaskAuthoringDevice")
    }
}

private extension SCSIInquiryAttempt {
    init(raw: KMLinkSCSIInquiryResult, service: RegistryNode) {
        let data = SCSIInquiryAttempt.bytes(from: raw.data, length: Int(raw.dataLength))
        self.init(
            service: service,
            result: raw.result,
            pluginResult: raw.pluginResult,
            queryResult: raw.queryResult,
            exclusiveResult: raw.exclusiveResult,
            commandResult: raw.commandResult,
            serviceResponse: raw.serviceResponse,
            taskStatus: raw.taskStatus,
            bytesTransferred: raw.bytesTransferred,
            method: SCSIInquiryAttempt.string(from: raw.method),
            vendor: SCSIInquiryAttempt.string(from: raw.vendor),
            product: SCSIInquiryAttempt.string(from: raw.product),
            revision: SCSIInquiryAttempt.string(from: raw.revision),
            message: SCSIInquiryAttempt.string(from: raw.message),
            hexPrefix: data.prefix(48).map { String(format: "%02X", $0) }.joined()
        )
    }

    private static func string<T>(from tuple: T) -> String {
        var copy = tuple
        return withUnsafePointer(to: &copy) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { chars in
                String(cString: chars)
            }
        }
    }

    private static func bytes<T>(from tuple: T, length: Int) -> [UInt8] {
        var copy = tuple
        return withUnsafeBytes(of: &copy) { rawBuffer in
            Array(rawBuffer.prefix(max(0, min(length, rawBuffer.count))))
        }
    }
}
