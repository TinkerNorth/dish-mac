// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import Foundation
import SwiftUI

func batteryIsCharging(_ reading: BatteryReading) -> Bool {
    switch reading.state {
    case .charging, .full: true
    case .discharging, .unknown: false
    }
}

/// The SF Symbol steps with the level; the first row whose bound the level
/// is under wins, and a full bar is the fallthrough.
private let batterySymbolSteps: [(below: Int, symbol: String)] = [
    (13, "battery.0"),
    (38, "battery.25"),
    (63, "battery.50"),
    (88, "battery.75")
]

/// The bolt while charging, a half bar for an unknown level, else the bar
/// that matches the level.
func batterySymbol(_ reading: BatteryReading) -> String {
    if batteryIsCharging(reading) { return "battery.100.bolt" }
    guard let level = reading.level else { return "battery.50" }
    return batterySymbolSteps.first { level < $0.below }?.symbol ?? "battery.100"
}

/// The pill text: the percentage, or a dash when the pad reports no level.
func batteryLevelText(_ reading: BatteryReading, words: L10n = .app) -> String {
    guard let level = reading.level else { return "—" }
    return words.percent(level)
}

private let batteryTintSteps: [(below: Int, color: Color)] = [
    (15, DishTheme.error),
    (30, DishTheme.warning)
]

/// Green while charging, red then amber as the level drops, muted otherwise.
func batteryTint(_ reading: BatteryReading) -> Color {
    if batteryIsCharging(reading) { return DishTheme.success }
    guard let level = reading.level else { return DishTheme.muted }
    return batteryTintSteps.first { level < $0.below }?.color ?? DishTheme.muted
}

/// The tooltip: the state in words, with the level when the pad reports one.
func batteryHelp(_ reading: BatteryReading, words: L10n = .app) -> String {
    switch (reading.state, reading.level) {
    case (.full, _): words.batteryFull
    case let (.charging, level?): words.batteryPercentCharging(level)
    case (.charging, nil): words.batteryCharging
    case let (.discharging, level?), let (.unknown, level?): words.batteryPercent(level)
    case (.discharging, nil), (.unknown, nil): words.batteryLevelUnknown
    }
}
