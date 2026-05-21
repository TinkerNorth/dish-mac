// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import os

/// Per-device, per-finger touchpad tracking-id state. `pushTouchpad` runs on a
/// GameController callback thread, so every access is `os_unfair_lock`-guarded
/// — the same discipline as `ClientRef`. The id-advance arithmetic itself is
/// the pure, unit-tested `nextTouchpadTrackingId`.
///
/// Split out of `GameControllerInput.swift` (it has no dependency on that
/// type) to keep both files under the lint length budget.
final class TouchpadTrackingState: @unchecked Sendable {
    /// Last-seen active flag + current id for one finger slot.
    private struct FingerState {
        var wasActive = false
        var id: UInt8 = 0
    }

    private struct DeviceState {
        var finger0 = FingerState()
        var finger1 = FingerState()
    }

    private var devices: [String: DeviceState] = [:]
    private var lock = os_unfair_lock_s()

    /// Advance both fingers' ids for one sample and return the ids to stamp on
    /// the wire. Each id bumps on its finger's `false → true` (fresh-contact)
    /// edge; see `nextTouchpadTrackingId`.
    func advance(
        deviceId: String,
        finger0Active: Bool,
        finger1Active: Bool
    ) -> (finger0: UInt8, finger1: UInt8) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        var state = devices[deviceId] ?? DeviceState()
        state.finger0.id = nextTouchpadTrackingId(
            wasActive: state.finger0.wasActive,
            isActive: finger0Active,
            current: state.finger0.id
        )
        state.finger1.id = nextTouchpadTrackingId(
            wasActive: state.finger1.wasActive,
            isActive: finger1Active,
            current: state.finger1.id
        )
        state.finger0.wasActive = finger0Active
        state.finger1.wasActive = finger1Active
        devices[deviceId] = state
        return (state.finger0.id, state.finger1.id)
    }

    /// Drop a device's state when its controller disconnects.
    func remove(deviceId: String) {
        os_unfair_lock_lock(&lock)
        devices.removeValue(forKey: deviceId)
        os_unfair_lock_unlock(&lock)
    }
}
