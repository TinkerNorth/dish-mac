// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

extension L10n {

    // MARK: - Settings

    var forwardedFeaturesSection: String {
        catalog.text("FORWARDED FEATURES")
    }

    var motionGyro: String {
        catalog.text("Motion (gyro)")
    }

    var motionDetail: String {
        catalog.text("Forward gyroscope and accelerometer to the host — used for motion aiming in games that support it.")
    }

    var rumbleDetail: String {
        catalog.text("Play vibration the host game sends back on your controller.")
    }

    var touchpadDetail: String {
        catalog.text("Forward the DualSense / DualShock 4 touchpad. Controllers without a touchpad ignore this.")
    }

    var featuresFootnote: String {
        catalog.text("Features only apply when your controller's hardware supports them — the controller list shows what was detected.")
    }

    var lightbarDetail: String {
        catalog.text("Follow game: the controller LED matches the host game. Off: leave the LED untouched.")
    }

    var followGame: String {
        catalog.text("Follow game")
    }

    var off: String {
        catalog.text("Off")
    }
}
