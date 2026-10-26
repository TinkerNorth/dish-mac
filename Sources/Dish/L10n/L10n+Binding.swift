// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

extension L10n {

    // MARK: - Configure binding: the sections

    var inputSection: String {
        catalog.text("Input")
    }

    var destinationSection: String {
        catalog.text("Destination")
    }

    var functionsSection: String {
        catalog.text("Functions")
    }

    func moonlightHostAt(_ address: String) -> String {
        catalog.format("Moonlight host · %@", address)
    }

    var noHostsFound: String {
        catalog.text("No hosts found")
    }

    func pairAHostThenBind(_ pad: String) -> String {
        catalog.format("Pair a Satellite or a Moonlight host on Connections, then come back to bind %@.", pad)
    }

    var manageDestinations: String {
        catalog.text("Manage destinations ›")
    }

    // MARK: - Configure binding: the switches

    var motionSwitchDetail: String {
        catalog.text("Tilt and gyro aiming on the host.")
    }

    var rumbleSwitchDetail: String {
        catalog.text("Feedback from the host drives the pad’s motors.")
    }

    var controllerSound: String {
        catalog.text("Controller sound")
    }

    var nothingToTune: String {
        catalog.text("Nothing to tune for this combination — see why on the right. The pad is ready to bind.")
    }

    // MARK: - Configure binding: what carries and the bar

    var pendingLower: String {
        catalog.text("pending")
    }

    func carriedOf(_ carried: Int, _ total: Int) -> String {
        catalog.format("%lld/%lld live", carried, total)
    }

    var pickADestination: String {
        catalog.text("Pick a destination to continue.")
    }

    var nothingIsSentUntilYouApply: String {
        catalog.text("Nothing is sent until you apply.")
    }

    var apply: String {
        catalog.text("Apply")
    }

    var leaveWithoutApplying: String {
        catalog.text("Leave without applying?")
    }

    var changesWillBeDiscarded: String {
        catalog.text("Nothing has been sent yet. Your changes will be discarded.")
    }

    var keepEditing: String {
        catalog.text("Keep editing")
    }

    // MARK: - Configure binding: the apply overlay

    var applyingEyebrow: String {
        catalog.text("Applying")
    }

    var applyingBinding: String {
        catalog.text("Applying binding…")
    }

    var sendingEachSetting: String {
        catalog.text("Sending each setting to the host.")
    }

    var applyingOnTheHost: String {
        catalog.text("Applying on the host")
    }

    var done: String {
        catalog.text("Done")
    }

    func controllerBound(_ pad: String, _ host: String) -> String {
        catalog.format("Controller bound — %@ is live on %@.", pad, host)
    }

    func refusedTheBinding(_ host: String) -> String {
        catalog.format("%@ refused the binding.", host)
    }

    func noLongerAvailable(_ pad: String) -> String {
        catalog.format("%@ is no longer available. Unplug and reconnect it, then try again.", pad)
    }

    var applyCancelled: String {
        catalog.text("Apply cancelled. Nothing was changed.")
    }
}
