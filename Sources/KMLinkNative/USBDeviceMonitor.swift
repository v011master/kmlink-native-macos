import Foundation
import IOKit

struct USBDeviceSnapshot: Equatable {
    let isConnected: Bool
    let vendorID: Int
    let productID: Int
    let productName: String?
    let serialNumber: String?
    let locationID: Int?

    var statusLine: String {
        guard isConnected else {
            return String(format: "USB: disconnected (%04X:%04X)", vendorID, productID)
        }

        let name = productName ?? "Unknown"
        let serial = serialNumber.map { " serial=\($0)" } ?? ""
        return String(format: "USB: %@ (%04X:%04X)%@", name, vendorID, productID, serial)
    }

    static let disconnected = USBDeviceSnapshot(
        isConnected: false,
        vendorID: USBDeviceMonitor.vendorID,
        productID: USBDeviceMonitor.productID,
        productName: nil,
        serialNumber: nil,
        locationID: nil
    )
}

final class USBDeviceMonitor {
    static let vendorID = 0x0EA0
    static let productID = 0x2213

    var onChange: ((USBDeviceSnapshot) -> Void)?
    private(set) var snapshot: USBDeviceSnapshot = .disconnected

    private var timer: Timer?

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func poll() {
        let next = Self.currentSnapshot()
        guard next != snapshot else {
            return
        }

        snapshot = next
        onChange?(next)
    }

    static func currentSnapshot() -> USBDeviceSnapshot {
        let matching = IOServiceMatching("IOUSBDevice") as NSMutableDictionary
        matching["idVendor"] = NSNumber(value: vendorID)
        matching["idProduct"] = NSNumber(value: productID)

        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else {
            return .disconnected
        }
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        guard service != 0 else {
            return .disconnected
        }
        defer { IOObjectRelease(service) }

        return USBDeviceSnapshot(
            isConnected: true,
            vendorID: vendorID,
            productID: productID,
            productName: stringProperty("USB Product Name", service: service) ?? stringProperty("kUSBProductString", service: service),
            serialNumber: stringProperty("USB Serial Number", service: service) ?? stringProperty("kUSBSerialNumberString", service: service),
            locationID: intProperty("locationID", service: service)
        )
    }

    private static func stringProperty(_ key: String, service: io_service_t) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }
        return value as? String
    }

    private static func intProperty(_ key: String, service: io_service_t) -> Int? {
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }
        return (value as? NSNumber)?.intValue
    }
}
