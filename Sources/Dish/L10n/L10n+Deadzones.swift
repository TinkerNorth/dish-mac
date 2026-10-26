// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

extension L10n {

    // MARK: - Dead zones & motion

    var deadZonesAndMotion: String {
        catalog.text("Dead zones & motion")
    }

    var stickDeadZone: String {
        catalog.text("Stick dead zone")
    }

    var triggerDeadZone: String {
        catalog.text("Trigger dead zone")
    }

    var resetToDefaults: String {
        catalog.text("Reset to defaults")
    }

    func resetDeadZonesFor(_ pad: String) -> String {
        catalog.format("Reset dead zones for %@", pad)
    }

    var forwardMotion: String {
        catalog.text("Forward motion (gyro)")
    }

    var forwardMotionDetail: String {
        catalog.text("Send gyroscope and accelerometer readings to the host.")
    }

    var motionForwardingUnavailable: String {
        catalog.text("Motion forwarding unavailable — this device has no gyroscope.")
    }

    var overridesArePerDevice: String {
        catalog.text("Overrides are stored per device and take effect immediately.")
    }

    var connectAControllerForDeadZones: String {
        catalog.text("Connect a controller to adjust its dead zones.")
    }
}
