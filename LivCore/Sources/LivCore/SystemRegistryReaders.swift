import Foundation
import IOKit

/// GPU and storage readings from the IOKit registry. Public API, no permission needed; only reads. The property names
/// vary by hardware and macOS version, so the parsers (`GPUParser`, `DiskIOParser`) treat a missing one as unavailable.
extension SystemReaders {
    static func gpu() -> GPUReading? {
        var entries: [(id: UInt64, properties: [String: Any])] = []
        registryEntries(matching: "IOAccelerator") { id, properties in entries.append((id, properties)) }
        return GPUParser.reading(from: entries)
    }

    static func diskCounters() -> [UInt64: DiskIOCounter]? {
        var counters: [UInt64: DiskIOCounter] = [:]
        registryEntries(matching: "IOBlockStorageDriver") { id, properties in
            if let counter = DiskIOParser.counter(properties: properties) { counters[id] = counter }
        }
        return counters.isEmpty ? nil : counters
    }

    private static func registryEntries(matching name: String, body: (UInt64, [String: Any]) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var id: UInt64 = 0
            var values: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS,
                  IORegistryEntryCreateCFProperties(service, &values, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = values?.takeRetainedValue() as? [String: Any]
            else { continue }
            body(id, properties)
        }
    }
}
