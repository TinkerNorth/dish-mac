// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation
import IOKit
import IOKit.pwr_mgt

/// Holds the machine awake as far as a `KeepAwakeReach` says. Tests inject
/// a fake; the IOKit one needs a display the CI host has not got.
protocol WakeInhibitor: AnyObject {
    /// Idempotent for a repeated reach; a different reach swaps the hold.
    func hold(_ reach: KeepAwakeReach, reason: String)
    /// Idempotent: releasing while not held is a no-op.
    func release()
    var held: KeepAwakeReach { get }
}

/// One `IOPMAssertion` at a time: preventing idle system sleep for
/// `system`, preventing idle display sleep for `systemAndDisplay` (which the
/// kernel treats as implying the system). The assertion's lifetime is tied
/// to the object's: `deinit` releases.
final class IOKitWakeInhibitor: WakeInhibitor {

    private var assertionID: IOPMAssertionID = 0
    private(set) var held: KeepAwakeReach = .none

    func hold(_ reach: KeepAwakeReach, reason: String) {
        guard reach != held else { return }
        release()
        guard let type = Self.assertionType(for: reach) else { return }
        var newID: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &newID)
        if status == kIOReturnSuccess {
            assertionID = newID
            held = reach
        }
    }

    func release() {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        held = .none
    }

    /// The IOKit assertion a reach maps to; none for `.none`.
    static func assertionType(for reach: KeepAwakeReach) -> String? {
        switch reach {
        case .none: nil
        case .system: kIOPMAssertionTypePreventUserIdleSystemSleep as String
        case .systemAndDisplay: kIOPMAssertionTypePreventUserIdleDisplaySleep as String
        }
    }

    deinit {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
        }
    }
}
