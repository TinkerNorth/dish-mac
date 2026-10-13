// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

extension L10n {

    // MARK: - Appearance

    var appearanceSection: String {
        catalog.text("APPEARANCE")
    }

    var theme: String {
        catalog.text("Theme")
    }

    var themeDetail: String {
        catalog.text("Choose how Dish looks. System matches your desktop’s light or dark setting.")
    }

    var themeSystem: String {
        catalog.text("System")
    }

    var themeLight: String {
        catalog.text("Light")
    }

    var themeDark: String {
        catalog.text("Dark")
    }

    // MARK: - Window

    var windowSection: String {
        catalog.text("WINDOW")
    }

    var keepRunningInBackground: String {
        catalog.text("Keep running in the background")
    }

    var keepRunningDetail: String {
        catalog.text("Closing the window keeps controllers streaming. Quit from the menu bar icon.")
    }

    var stillRunningTitle: String {
        catalog.text("Dish is still running")
    }

    var stillRunningBody: String {
        catalog.text("Controllers keep streaming. Quit from the menu bar icon.")
    }

    var showDish: String {
        catalog.text("Show Dish")
    }

    var quit: String {
        catalog.text("Quit")
    }

    // MARK: - Power

    var powerSection: String {
        catalog.text("POWER")
    }

    var keepComputerAwake: String {
        catalog.text("Keep the computer awake")
    }

    var whilePlaying: String {
        catalog.text("While playing")
    }

    var whileConnected: String {
        catalog.text("While connected")
    }

    var keepAwakeDetail: String {
        catalog.text("While playing: only while a bound controller is in use. While connected: as long as a controller streams, even idle.")
    }

    var letGoAfterStillness: String {
        catalog.text("Let go after this much stillness")
    }

    var keepDisplayAwake: String {
        catalog.text("Keep the display awake too")
    }

    var keepDisplayAwakeDetail: String {
        catalog
            .text(
                "Forwarding a controller needs the machine, not the screen, so this is off unless a game is being watched on this display."
            )
    }

    func minutes(_ count: Int) -> String {
        catalog.format("%lld min", count)
    }
}
