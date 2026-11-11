// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The battery a pad's MSG_BATTERY carries when two batteries compete, the
// pad's own and the Mac's: the lower of the two, whatever the link. The
// desktops' `lowestBattery` (BatteryRouting.h), with no wired special case.

import Foundation

/// The lower of the pad's own battery and the Mac's. A pad with no battery
/// sends the Mac's; an unknown level sorts above every known one; on a tie
/// the pad's sample wins, and the status travels with whichever wins.
public func lowestBattery(pad: PadBattery?, host: PadBattery) -> PadBattery {
    guard let pad else { return host }
    let hostIsLower = comparableBatteryLevel(host) < comparableBatteryLevel(pad)
    return hostIsLower ? host : pad
}

/// The unknown sentinel as +infinity, so a known level always wins.
private func comparableBatteryLevel(_ battery: PadBattery) -> Int {
    battery.level == ProtocolConstants.batteryLevelUnknown ? Int.max : Int(battery.level)
}
