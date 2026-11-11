// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation
import IOKit.ps

/// Reads the *host Mac's* power state, the battery that competes with the
/// pad's own: MSG_BATTERY carries the lower of the two (`lowestBattery`),
/// and a pad that reports no charge of its own sends this one. A laptop
/// reports its own percentage and charge state; a desktop Mac (Mac mini,
/// Studio, Pro: no internal battery) reports level=100, status=wired, the
/// honest "AC-powered, no battery" signal the wire's `wired` status names.
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

    /// Pure mapping from an IOKit-free snapshot to the wire reading. Extracted
    /// so unit tests can pin every branch without touching IOKit:
    ///
    ///   * `nil` snapshot → no internal battery (desktop Mac) → level=100,
    ///     status=wired. This is the AC-powered host the `wired` status names.
    ///   * a snapshot with a `nil` percentage → level=0xFF (unknown) carrying
    ///     the best-known charge state.
    ///   * a snapshot with a percentage → the clamped percentage + the
    ///     discharging/charging/full state.
    static func reading(from snapshot: Snapshot?) -> PadBattery {
        guard let snapshot else {
            // No internal battery power source: a desktop Mac. The controller
            // is, transitively, mains-powered.
            return PadBattery(level: 100, status: .wired)
        }
        let status: BatteryStatus = switch snapshot.state {
        case .unknown: .unknown
        case .discharging: .discharging
        case .charging: .charging
        case .full: .full
        }
        guard let percentage = snapshot.percentage else {
            return PadBattery(level: ProtocolConstants.batteryLevelUnknown, status: status)
        }
        let clamped = min(100, max(0, percentage))
        return PadBattery(level: UInt8(clamped), status: status)
    }

    /// Read the host Mac's internal-battery power source via IOKit. Returns
    /// `nil` when the machine has no internal battery (desktop Mac) — the
    /// caller maps that to `status=wired` through `reading(from:)`.
    ///
    /// `IOPSCopyPowerSourcesInfo` is a blocking snapshot of the power
    /// manager's published state, so it is read on the battery queue, never
    /// on the main actor or an input thread.
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

/// The Mac's battery, read through IOKit: the bridge's default.
@Sendable
func liveHostBattery() -> PadBattery {
    HostBattery.reading(from: HostBattery.snapshot())
}
