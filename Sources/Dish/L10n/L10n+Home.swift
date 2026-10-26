// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

extension L10n {

    // MARK: - Home: the signal path

    var setUpAController: String {
        catalog.text("Set up a controller")
    }

    var bindEllipsis: String {
        catalog.text("Bind…")
    }

    var chooseASatelliteForThisPad: String {
        catalog.text("Choose a satellite for this pad")
    }

    var editChevron: String {
        catalog.text("Edit ›")
    }

    var configureBinding: String {
        catalog.text("Configure binding")
    }

    var unboundTitle: String {
        catalog.text("Unbound")
    }

    var live: String {
        catalog.text("live")
    }

    var wireHelp: String {
        catalog.text("Report rate: measured. Latency: median round-trip ÷ 2 over the last 64 pings.")
    }

    func slotOf(_ ordinal: Int, _ capacity: Int) -> String {
        catalog.format("slot %lld of %lld", ordinal, capacity)
    }

    func emulatedAs(_ typeName: String) -> String {
        catalog.format("as %@", typeName)
    }

    // MARK: - The telemetry footer

    func eventsAndSends(_ events: Int, _ sends: Int) -> String {
        catalog.format("events/s %lld   sends/s %lld", events, sends)
    }

    func totalSent(_ total: Int) -> String {
        catalog.format("total %lld", total)
    }
}
