// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation
import IOKit
import IOKit.pwr_mgt

/// Holds the system display awake while Dish is streaming. The macOS analogue
/// of Android's `WakeStateController` — there the equivalent calls are
/// `PowerManager.PARTIAL_WAKE_LOCK` (CPU) + `FLAG_KEEP_SCREEN_ON` (display);
/// on macOS a single `IOPMAssertion` of type
/// `kIOPMAssertionTypePreventUserIdleDisplaySleep` covers both, because the
/// display assertion implicitly keeps the CPU awake.
///
/// Tests inject a `FakeDisplaySleepInhibitor` to verify the acquire / release
/// lifecycle without hitting IOKit (which has no host equivalent off-device).
protocol DisplaySleepInhibitor: AnyObject {
    /// Idempotent: a second call with the same reason while already held is
    /// a no-op so callers don't need to track state themselves.
    func acquire(reason: String)
    /// Idempotent: releasing while not held is a no-op.
    func release()
    /// True iff an assertion is currently held.
    var isHeld: Bool { get }
}

/// Production implementation. Held in a dedicated class so the assertion
/// lifetime is tied to the object's lifetime — `deinit` releases on dealloc.
final class IOKitDisplaySleepInhibitor: DisplaySleepInhibitor {

    private var assertionID: IOPMAssertionID = 0

    var isHeld: Bool { assertionID != 0 }

    func acquire(reason: String) {
        guard assertionID == 0 else { return }
        var newID: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &newID
        )
        if status == kIOReturnSuccess {
            assertionID = newID
        }
    }

    func release() {
        guard assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
    }

    deinit {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
        }
    }
}
