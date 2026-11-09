// Adapted from coffe-awake (PowerAssertions), GPL-3, same author.
import Foundation
import IOKit.pwr_mgt
import os

/// Holds PreventUserIdleSystemSleep and PreventUserIdleDisplaySleep. powerd counts assertions per process, so another
/// keep-awake app's assertions are neither affected nor affecting ours. The OS also frees them if this process dies.
nonisolated final class LivePowerAssertions: PowerAssertionHolding {
    private let ids = OSAllocatedUnfairLock(initialState: [IOPMAssertionID]())

    var isHeld: Bool { ids.withLock { !$0.isEmpty } }

    func acquire(reason: String) throws {
        try ids.withLock { held in
            guard held.isEmpty else { return }
            for type in [kIOPMAssertionTypePreventUserIdleSystemSleep, kIOPMAssertionTypePreventUserIdleDisplaySleep] {
                var id = IOPMAssertionID(0)
                let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
                guard result == kIOReturnSuccess else {
                    held.forEach { _ = IOPMAssertionRelease($0) }
                    held.removeAll()
                    throw PowerAssertionError(code: result)
                }
                held.append(id)
            }
        }
    }

    func release() {
        ids.withLock { held in
            held.forEach { _ = IOPMAssertionRelease($0) }
            held.removeAll()
        }
    }

    deinit { release() }
}

nonisolated struct PowerAssertionError: LocalizedError {
    let code: IOReturn
    var errorDescription: String? { "Unable to keep the Mac awake (error code \(code))." }
}
