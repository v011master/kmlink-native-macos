import Foundation
import IOKit
import KMLinkNativeCSCSI

struct VendorCommandSnapshot {
    let preparation: String
    let attempts: [VendorCommandAttempt]

    var statusLine: String {
        let successes = attempts.filter(\.succeeded)
        if !successes.isEmpty {
            return "vendorCommands: \(successes.count)/\(attempts.count) read probe(s) ok"
        }
        if attempts.isEmpty {
            return "vendorCommands: no service"
        }
        return "vendorCommands: \(attempts.count) read probe(s) failed"
    }

    var diagnostics: String {
        var lines = ["transport.vendorCommands: \(statusLine)"]
        lines.append("  preparation: \(preparation)")
        lines.append(contentsOf: attempts.map { "  - \($0.diagnosticLine)" })
        return lines.joined(separator: "\n")
    }

    static let empty = VendorCommandSnapshot(preparation: "not attempted", attempts: [])
}

struct VendorCommandAttempt {
    let name: String
    let result: Int32
    let pluginResult: Int32
    let queryResult: Int32
    let exclusiveResult: Int32
    let commandResult: Int32
    let serviceResponse: UInt32
    let taskStatus: UInt32
    let bytesTransferred: UInt64
    let data: [UInt8]
    let message: String

    var succeeded: Bool {
        result == 0
    }

    var diagnosticLine: String {
        "\(name) result=\(result) plugin=\(hex(pluginResult)) query=\(queryResult) exclusive=\(hex(exclusiveResult)) command=\(hex(commandResult)) response=\(serviceResponse) status=\(taskStatus) bytes=\(bytesTransferred) data=\(data.prefix(64).map { String(format: "%02X", $0) }.joined()) message=\(message)"
    }

    private func hex(_ value: Int32) -> String {
        String(format: "0x%08X", UInt32(bitPattern: value))
    }
}

enum VendorCommandProbe {
    static func probe(from root: io_registry_entry_t) -> VendorCommandSnapshot {
        guard let service = firstCompactDiscService(from: root) else {
            return .empty
        }
        defer { IOObjectRelease(service) }

        let preparation = SCSIMediaPreparer.unmountMediaIfPresent(from: root)
        let commands: [(String, [UInt8], UInt32)] = [
            ("icVersion", cdb(opcode: 0xF0), 12),
            ("physicalBusType", cdb(opcode: 0xF0, byte2: 0x02), 64),
            ("deviceMode", cdb(opcode: 0xD9, byte1: 0x60), 64),
            ("genderStatus", cdb(opcode: 0xD9, byte1: 0x60, byte2: 0x02), 64)
        ]

        let attempts = commands.map { name, cdb, receiveLength in
            run(name: name, cdb: cdb, receiveLength: receiveLength, service: service)
        }
        return VendorCommandSnapshot(preparation: preparation, attempts: attempts)
    }

    private static func run(name: String, cdb: [UInt8], receiveLength: UInt32, service: io_service_t) -> VendorCommandAttempt {
        var raw = KMLinkSCSICommandResult()
        cdb.withUnsafeBufferPointer { cdbBuffer in
            KMLinkSCSICommand(
                service,
                cdbBuffer.baseAddress,
                UInt8(cdb.count),
                nil,
                0,
                receiveLength,
                2,
                &raw
            )
        }
        return VendorCommandAttempt(raw: raw, name: name)
    }

    private static func cdb(opcode: UInt8, byte1: UInt8 = 0, byte2: UInt8 = 0) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = opcode
        bytes[1] = byte1
        bytes[2] = byte2
        bytes[14] = 0x4F
        bytes[15] = 0x54
        return bytes
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

}

private extension VendorCommandAttempt {
    init(raw: KMLinkSCSICommandResult, name: String) {
        self.init(
            name: name,
            result: raw.result,
            pluginResult: raw.pluginResult,
            queryResult: raw.queryResult,
            exclusiveResult: raw.exclusiveResult,
            commandResult: raw.commandResult,
            serviceResponse: raw.serviceResponse,
            taskStatus: raw.taskStatus,
            bytesTransferred: raw.bytesTransferred,
            data: Self.bytes(from: raw.data, length: Int(raw.dataLength)),
            message: Self.string(from: raw.message)
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
