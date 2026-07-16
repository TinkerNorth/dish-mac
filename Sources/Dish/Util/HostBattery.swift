// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation
import IOKit.ps

/// Reads the *host Mac's* power state as a fallback battery source. A
/// controller that doesn't surface its own charge — a wired/USB pad, or one
/// whose `GCDeviceBattery` reports an unknown level — would otherwise show as
/// "wired"/"unknown" on the satellite. We instead report the Mac it's plugged
/// into: a laptop forwards its own battery percentage + charge state; a
/// desktop Mac (Mac mini / Studio / Pro — no internal battery) reports
/// level=100, status=wired, which is the honest "AC-powered, no battery"
/// signal the wire protocol's `wired` status was defined for.
///
/// The IOKit power-source plumbing is isolated to `snapshot()`; the
/// snapshot → wire mapping is the pure `reading(from:)` function so the
/// arithmetic is unit-testable without an IOKit dependency.
enum HostBattery {

    /// Charge state of the host Mac's internal battery. Mirrors the subset of
    /// `GCDeviceBattery.State` the host can be in — a Mac never reports
    /// `wired` here; that maps in at the `reading(from:)` boundary when there
    /// is no internal battery at all.
    enum ChargeState {
        case unknown, discharging, charging, full
    }

    /// A plain-data view of the host's internal-battery power source. `nil`
    /// `percentage` means the source exists but isn't reporting a usable
    /// capacity yet; a `nil` `Snapshot` (see `snapshot()`) means there is no
    /// internal battery at all (desktop Mac).
    struct Snapshot: Equatable {
        /// Current charge 0...100, already clamped. `nil` when the power
        /// source omits or zeroes its capacity keys.
        let percentage: Int?
        let state: ChargeState
    }

    /// Wire-ready battery reading: `level` is 0...100 or `0xFF` (unknown);
    /// `status` is a `DishCore.BatteryStatus` raw value.
    struct WireReading: Equatable {
        let level: UInt8
        let status: BatteryStatus
    }

    /// Pure mapping from an IOKit-free snapshot to the wire reading. Extracted
    /// so unit tests can pin every branch without touching IOKit:
    ///
    ///   * `nil` snapshot → no internal battery (desktop Mac) → level=100,
    ///     status=wired. This is the AC-powered host the `wired` status names.
    ///   * a snapshot with a `nil` percentage → level=0xFF (unknown) carrying
    ///     the best-known charge state.
    ///   * a snapshot with a percentage → the clamped percentage + the
    ///     discharging/charging/full state.
    static func reading(from snapshot: Snapshot?) -> WireReading {
        guard let snapshot else {
            // No internal battery power source: a desktop Mac. The controller
            // is, transitively, mains-powered.
            return WireReading(level: 100, status: .wired)
        }
        let status: BatteryStatus = switch snapshot.state {
        case .unknown: .unknown
        case .discharging: .discharging
        case .charging: .charging
        case .full: .full
        }
        guard let percentage = snapshot.percentage else {
            return WireReading(level: 0xFF, status: status)
        }
        let clamped = min(100, max(0, percentage))
        return WireReading(level: UInt8(clamped), status: status)
    }

    /// Read the host Mac's internal-battery power source via IOKit. Returns
    /// `nil` when the machine has no internal battery (desktop Mac) — the
    /// caller maps that to `status=wired` through `reading(from:)`.
    ///
    /// `IOPSCopyPowerSourcesInfo` is a cheap blocking snapshot of the power
    /// manager's published state; it's safe to call from the battery poll
    /// timer's main-queue tick.
    static func snapshot() -> Snapshot? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue()
              as? [CFTypeRef] else
        {
            return nil
        }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else
            {
                continue
            }
            // Only the internal battery is a meaningful host fallback — skip
            // UPSes and any other power source the API may surface.
            guard desc[kIOPSTypeKey as String] as? String
                == kIOPSInternalBatteryType else
            {
                continue
            }
            return parseInternalBattery(desc)
        }
        return nil
    }

    /// Map a single `kIOPSInternalBatteryType` power-source description
    /// dictionary into a `Snapshot`. Split out from `snapshot()` so the key
    /// lookups are exercised in one place; still IOKit-coupled (it consumes
    /// the raw `kIOPS*` keys) so it stays `private`.
    private static func parseInternalBattery(_ desc: [String: Any]) -> Snapshot {
        let current = desc[kIOPSCurrentCapacityKey as String] as? Int
        let max = desc[kIOPSMaxCapacityKey as String] as? Int
        let percentage: Int? = if let current, let max, max > 0 {
            min(100, max == 0 ? 0 : (current * 100) / max)
        } else {
            nil
        }

        let isCharging = desc[kIOPSIsChargingKey as String] as? Bool ?? false
        let powerState = desc[kIOPSPowerSourceStateKey as String] as? String

        let state: ChargeState = if isCharging {
            // A battery at 100 % while still on AC reports `isCharging` true
            // until the charger backs off; treat that as `full` so the pill
            // doesn't flicker a bolt at a topped-up battery.
            (percentage ?? 0) >= 100 ? .full : .charging
        } else if powerState == (kIOPSACPowerValue as String) {
            // On AC but not charging → topped up.
            .full
        } else if powerState == (kIOPSBatteryPowerValue as String) {
            .discharging
        } else {
            .unknown
        }
        return Snapshot(percentage: percentage, state: state)
    }
}
