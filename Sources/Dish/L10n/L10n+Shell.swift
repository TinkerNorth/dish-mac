// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

extension L10n {

    // MARK: - Rail

    var home: String {
        catalog.text("Home")
    }

    func railVersion(_ version: String) -> String {
        catalog.format("Dish %@", version)
    }

    // MARK: - Header

    var back: String {
        catalog.text("Back")
    }

    var streamingComputerKeptAwake: String {
        catalog.text("Streaming · computer kept awake")
    }

    var streamingDisplayKeptAwake: String {
        catalog.text("Streaming · display kept awake")
    }

    var configure: String {
        catalog.text("Configure")
    }

    var configureKeepAwake: String {
        catalog.text("Configure keep-awake")
    }

    // MARK: - Home

    var nothingSetUpYet: String {
        catalog.text("Nothing set up yet")
    }

    var plugOneIn: String {
        catalog.text("Plug one in, then pick where it goes")
    }

    var plugInAndPairToGetStarted: String {
        catalog.text("Plug in a controller and pair a Satellite to get started")
    }

    // MARK: - Settings

    var controllerTuningSection: String {
        catalog.text("Controller tuning")
    }

    var diagnosticsEllipsis: String {
        catalog.text("Diagnostics…")
    }
}
