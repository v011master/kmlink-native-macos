import Foundation
import IOKit

struct TransportProbeSnapshot {
    let usbPath: String?
    let usbChildren: [RegistryNode]
    let scsiCandidates: [RegistryNode]
    let bsdMediaCandidates: [RegistryNode]
    let scsiInquiry: SCSIInquirySnapshot
    let vendorCommands: VendorCommandSnapshot

    var statusLine: String {
        if scsiInquiry.best != nil {
            return scsiInquiry.statusLine
        }

        if !scsiCandidates.isEmpty {
            return "Transport: \(scsiCandidates.count) SCSI candidate(s); \(scsiInquiry.statusLine)"
        }

        if !usbChildren.isEmpty {
            return "Transport: USB node found, no SCSI child yet"
        }

        return "Transport: no usable transport node"
    }

    var diagnostics: String {
        var lines: [String] = []
        lines.append("transport.status: \(statusLine)")
        lines.append("transport.usbPath: \(usbPath ?? "nil")")
        lines.append("transport.usbChildren:")
        lines.append(contentsOf: usbChildren.map { "  - \($0.compactLine)" })
        lines.append("transport.scsiCandidates:")
        lines.append(contentsOf: scsiCandidates.map { "  - \($0.compactLine)" })
        lines.append("transport.bsdMediaCandidates:")
        lines.append(contentsOf: bsdMediaCandidates.map { "  - \($0.compactLine)" })
        lines.append(scsiInquiry.diagnostics)
        lines.append(vendorCommands.diagnostics)
        return lines.joined(separator: "\n")
    }

    static let empty = TransportProbeSnapshot(
        usbPath: nil,
        usbChildren: [],
        scsiCandidates: [],
        bsdMediaCandidates: [],
        scsiInquiry: .empty,
        vendorCommands: .empty
    )
}

struct RegistryNode {
    let ioClass: String
    let name: String
    let path: String
    let properties: [String: String]

    var compactLine: String {
        let props = properties
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        return props.isEmpty ? "\(ioClass) \(name) \(path)" : "\(ioClass) \(name) \(props)"
    }
}

enum TransportProbe {
    static func currentSnapshot() -> TransportProbeSnapshot {
        guard let usbService = findUSBDevice() else {
            return .empty
        }
        defer { IOObjectRelease(usbService) }

        let path = registryPath(usbService)
        let descendants = collectDescendants(from: usbService, maxDepth: 8)
        let scsiInquiry = SCSIInquiryProbe.probe(from: usbService)
        let vendorCommands = VendorCommandProbe.probe(from: usbService)

        let scsiCandidates = descendants
            .filter { node in
                node.ioClass.localizedCaseInsensitiveContains("SCSI")
                    || node.ioClass.localizedCaseInsensitiveContains("MassStorage")
                    || node.properties.keys.contains("SCSITaskDeviceCategory")
                    || node.properties.keys.contains("SCSITaskAuthoringDevice")
            }
            .deduplicatedByPath()

        let bsdCandidates = descendants
            .filter { node in
                node.ioClass == "IOMedia" || node.ioClass == "IOBlockStorageDevice"
            }
            .deduplicatedByPath()

        return TransportProbeSnapshot(
            usbPath: path,
            usbChildren: descendants.prefix(30).map { $0 },
            scsiCandidates: scsiCandidates,
            bsdMediaCandidates: bsdCandidates,
            scsiInquiry: scsiInquiry,
            vendorCommands: vendorCommands
        )
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

    private static func collectDescendants(from service: io_service_t, maxDepth: Int) -> [RegistryNode] {
        var results: [RegistryNode] = []

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

                results.append(RegistryNode.make(child))
                visit(child, depth: depth + 1)
            }
        }

        visit(service, depth: 0)
        return results
    }

    private static func findGlobalCandidates(classes: [String]) -> [RegistryNode] {
        var nodes: [RegistryNode] = []

        for ioClass in classes {
            guard let matching = IOServiceMatching(ioClass) else {
                continue
            }

            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
                continue
            }
            defer { IOObjectRelease(iterator) }

            while true {
                let service = IOIteratorNext(iterator)
                if service == 0 {
                    break
                }
                defer { IOObjectRelease(service) }
                nodes.append(RegistryNode.make(service))
            }
        }

        return nodes
    }

    static func className(_ service: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        IOObjectGetClass(service, &buffer)
        return String(cString: buffer)
    }

    static func registryName(_ service: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard IORegistryEntryGetName(service, &buffer) == KERN_SUCCESS else {
            return "unknown"
        }
        return String(cString: buffer)
    }

    static func registryPath(_ service: io_registry_entry_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 2048)
        guard IORegistryEntryGetPath(service, kIOServicePlane, &buffer) == KERN_SUCCESS else {
            return nil
        }
        return String(cString: buffer)
    }

    static func selectedProperties(_ service: io_registry_entry_t) -> [String: String] {
        let keys = [
            "idVendor",
            "idProduct",
            "USB Product Name",
            "USB Serial Number",
            "kUSBProductString",
            "kUSBSerialNumberString",
            "locationID",
            "bInterfaceClass",
            "bInterfaceSubClass",
            "bInterfaceProtocol",
            "SCSITaskDeviceCategory",
            "SCSITaskAuthoringDevice",
            "BSD Name",
            "Removable",
            "Whole"
        ]

        var result: [String: String] = [:]
        for key in keys {
            guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
                continue
            }
            result[key] = stringify(value)
        }
        return result
    }

    private static func stringify(_ value: Any) -> String {
        switch value {
        case let number as NSNumber:
            return number.stringValue
        case let string as String:
            return string
        case let data as Data:
            return data.map { String(format: "%02X", $0) }.joined()
        default:
            return "\(value)"
        }
    }
}

extension RegistryNode {
    static func make(_ service: io_registry_entry_t) -> RegistryNode {
        RegistryNode(
            ioClass: TransportProbe.className(service),
            name: TransportProbe.registryName(service),
            path: TransportProbe.registryPath(service) ?? "",
            properties: TransportProbe.selectedProperties(service)
        )
    }
}

private extension Array where Element == RegistryNode {
    func deduplicatedByPath() -> [RegistryNode] {
        var seen = Set<String>()
        var result: [RegistryNode] = []

        for node in self {
            let key = node.path.isEmpty ? "\(node.ioClass):\(node.name)" : node.path
            guard seen.insert(key).inserted else {
                continue
            }
            result.append(node)
        }

        return result
    }
}
