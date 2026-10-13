// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

extension L10n {

    // MARK: - Slot card

    var unbind: String {
        catalog.text("Unbind")
    }

    var close: String {
        catalog.text("Close")
    }

    var bind: String {
        catalog.text("Bind")
    }

    var noConnectionsAddOne: String {
        catalog.text("No connections — add one from Manage")
    }

    var unbound: String {
        catalog.text("unbound")
    }

    func gamepadSubtitle(_ binding: String) -> String {
        catalog.format("Gamepad • %@", binding)
    }

    func boundTo(_ label: String) -> String {
        catalog.format("→ %@", label)
    }

    func boundUnsteady(_ label: String) -> String {
        catalog.format("→ %@ (unsteady)", label)
    }

    func boundConnecting(_ label: String) -> String {
        catalog.format("→ %@ (connecting…)", label)
    }

    func boundReady(_ label: String) -> String {
        catalog.format("→ %@ (ready)", label)
    }

    func boundOffline(_ label: String) -> String {
        catalog.format("→ %@ (offline)", label)
    }
}

extension L10n {

    // MARK: - Capability chips

    var gyro: String {
        catalog.text("Gyro")
    }

    var noGyro: String {
        catalog.text("No gyro")
    }

    var touchpad: String {
        catalog.text("Touchpad")
    }

    var rumble: String {
        catalog.text("Rumble")
    }

    var lightbar: String {
        catalog.text("Lightbar")
    }

    var motion: String {
        catalog.text("Motion")
    }

    var lightBar: String {
        catalog.text("Light bar")
    }

    var motionUnavailableHelp: String {
        catalog.text("Motion not available — this controller has no gyroscope or accelerometer.")
    }

    func detectedOn(_ feature: String) -> String {
        catalog.format("%@ detected — forwarding to the host is on", feature)
    }

    func detectedOff(_ feature: String) -> String {
        catalog.format("%@ detected — turned off in Settings", feature)
    }
}

extension L10n {

    // MARK: - Battery

    var batteryFull: String {
        catalog.text("Battery full")
    }

    var batteryCharging: String {
        catalog.text("Battery charging")
    }

    var batteryLevelUnknown: String {
        catalog.text("Battery level unknown")
    }

    func percent(_ level: Int) -> String {
        catalog.format("%lld%%", level)
    }

    func batteryPercent(_ level: Int) -> String {
        catalog.format("Battery %lld%%", level)
    }

    func batteryPercentCharging(_ level: Int) -> String {
        catalog.format("Battery %lld%% — charging", level)
    }
}
