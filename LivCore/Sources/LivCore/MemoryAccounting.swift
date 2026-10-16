import Foundation

/// The `vm_statistics64` page counts the memory figures are built from. Plain numbers, so the formula is
/// tested without asking the system.
public struct VMCounters: Sendable, Equatable {
    /// Anonymous pages (`internal_page_count`): what apps allocated.
    public var internalPages: UInt64
    public var purgeablePages: UInt64
    public var wiredPages: UInt64
    /// Pages the compressor occupies (`compressor_page_count`).
    public var compressorPages: UInt64
    /// File-backed pages (`external_page_count`).
    public var externalPages: UInt64
    public var pageSize: UInt64

    public init(
        internalPages: UInt64,
        purgeablePages: UInt64,
        wiredPages: UInt64,
        compressorPages: UInt64,
        externalPages: UInt64,
        pageSize: UInt64
    ) {
        self.internalPages = internalPages
        self.purgeablePages = purgeablePages
        self.wiredPages = wiredPages
        self.compressorPages = compressorPages
        self.externalPages = externalPages
        self.pageSize = pageSize
    }
}

/// Activity Monitor's definitions, measured against it on 2026-10-15:
///
/// - App Memory = anonymous pages minus purgeable ones.
/// - Memory Used = App Memory + Wired + Compressed.
/// - Cached Files = file-backed pages plus purgeable ones.
///
/// `active_count` is deliberately not used: anonymous pages that were not touched recently sit on the inactive
/// list and are still app memory, so adding "active" instead of App Memory undercounts by several GiB.
public enum MemoryAccounting {
    public static func reading(from counters: VMCounters, totalBytes: UInt64, pressure: MemoryPressure) -> MemoryReading {
        let page = counters.pageSize
        let appPages = counters.internalPages > counters.purgeablePages ? counters.internalPages - counters.purgeablePages : 0
        let app = appPages * page
        let wired = counters.wiredPages * page
        let compressed = counters.compressorPages * page
        return MemoryReading(
            totalBytes: totalBytes,
            usedBytes: app + wired + compressed,
            wiredBytes: wired,
            compressedBytes: compressed,
            pressure: pressure,
            appBytes: app,
            cachedBytes: (counters.externalPages + counters.purgeablePages) * page
        )
    }

    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical; anything else reads as normal.
    public static func pressure(forLevel level: Int32) -> MemoryPressure {
        switch level {
        case 4: .critical
        case 2: .warning
        default: .normal
        }
    }
}
