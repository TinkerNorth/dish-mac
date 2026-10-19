// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

extension L10n {

    // MARK: - Moonlight hosts on the Connections sheet

    var moonlightHostsSection: String {
        catalog.text("MOONLIGHT HOSTS")
    }

    var noMoonlightHostsHint: String {
        catalog.text("No Moonlight hosts yet. Scan your network or add one by address.")
    }

    var moonlightAddressPlaceholder: String {
        catalog.text("Host IP or name")
    }

    var enterTheHostAddress: String {
        catalog.text("Enter the host address")
    }

    var moonlightHost: String {
        catalog.text("Moonlight host")
    }

    var pairedTrust: String {
        catalog.text("Paired")
    }

    var notPaired: String {
        catalog.text("Not paired")
    }

    var pairNow: String {
        catalog.text("Pair now")
    }

    var rePair: String {
        catalog.text("Re-pair")
    }

    func closeTheAppOn(_ host: String) -> String {
        catalog.format("Close the app on %@", host)
    }

    var reconnect: String {
        catalog.text("Reconnect")
    }

    var retry: String {
        catalog.text("Retry")
    }

    var startASession: String {
        catalog.text("Start a session")
    }

    func controllersOnHost(_ count: Int) -> String {
        catalog.format("%lld controllers", count)
    }

    func forgetMoonlightHelp(_ host: String) -> String {
        catalog.format(
            "Dish deletes its pairing and you will need the PIN again. %@ keeps its own record of this device until you remove it there.",
            host
        )
    }

    var app: String {
        catalog.text("App")
    }

    func withoutAPick(_ host: String) -> String {
        catalog.format("Without a pick, Dish starts whatever %@ lists first.", host)
    }

    // MARK: - The PIN sheet

    func typePinInto(_ pin: String, _ host: String) -> String {
        catalog.format("Type %@ into the Moonlight or Sunshine page on %@.", pin, host)
    }

    var waitingForTheHostToAcceptThePin: String {
        catalog.text("Waiting for the host to accept the PIN…")
    }

    var newCode: String {
        catalog.text("New code")
    }

    // MARK: - The row's status line

    var notPairedYet: String {
        catalog.text("Not paired yet")
    }

    func noLongerRecognises(_ host: String) -> String {
        catalog.format("%@ no longer recognises this device", host)
    }

    func wasReset(_ host: String) -> String {
        catalog.format("%@ was reset", host)
    }

    func isNotAnswering(_ host: String) -> String {
        catalog.format("%@ is not answering", host)
    }

    func sessionOnHostEnded(_ host: String) -> String {
        catalog.format("Session on %@ ended", host)
    }

    func hostEndedTheSession(_ host: String) -> String {
        catalog.format("%@ ended the session", host)
    }

    func anotherDeviceIsUsing(_ host: String) -> String {
        catalog.format("Another device is using %@", host)
    }

    func couldNotRejoin(_ host: String) -> String {
        catalog.format("Could not rejoin the session on %@", host)
    }

    func refusedTheSession(_ host: String, _ reason: String) -> String {
        catalog.format("%@ refused the session: %@", host, reason)
    }

    func refusedTheSessionNoReason(_ host: String) -> String {
        catalog.format("%@ refused the session", host)
    }

    func couldNotFinishTheSession(_ host: String) -> String {
        catalog.format("Could not finish the session on %@", host)
    }

    var noAppsOnThisHost: String {
        catalog.text("No apps on this host")
    }

    func hostIsFull(_ host: String) -> String {
        catalog.format("%@ is full", host)
    }
}

extension L10n {

    // MARK: - What a host's events say

    func pairedWithHost(_ host: String) -> String {
        catalog.format("Paired with %@", host)
    }

    var pairedBody: String {
        catalog.text("Dish starts a session on this host as soon as a controller is bound to it.")
    }

    func didNotAcceptThePin(_ host: String) -> String {
        catalog.format("%@ did not accept the PIN", host)
    }

    var checkTheCodeWentIntoTheRightHost: String {
        catalog.text("Check that the code went into the right host, then try again.")
    }

    var noPairingIdentityYet: String {
        catalog.text("Dish has no pairing identity yet. Try again in a moment.")
    }

    var newIdentityBody: String {
        catalog.text("This host has a new identity, so the old pairing no longer works. Pair again to start a session.")
    }

    func runningAnAppForAnotherDevice(_ host: String) -> String {
        catalog.format(
            "%@ is running an app for another device and will not hand it over. Close it to start a new one, or try again later.",
            host
        )
    }

    func hostWouldNotHandItBack(_ host: String) -> String {
        catalog.format("The host has a session but would not hand it back. Close the app on %@ and start a new one.", host)
    }

    var addTheControllerAnyway: String {
        catalog.text("Add the controller anyway and Dish will try again the next time you use it.")
    }

    var theStreamDidNotComeUp: String {
        catalog.text("The app started but the stream did not come up, so Dish closed it again.")
    }

    func fourControllersAtMost(_ host: String) -> String {
        catalog.format("A session carries four controllers at most, and %@ already has four. Unbind one to make room.", host)
    }

    var theAppClosedOnTheHost: String {
        catalog.text("The app closed on the host. Start a new session to keep using this controller.")
    }

    func askedToCloseTheApp(_ host: String) -> String {
        catalog.format("Asked %@ to close the app it is running.", host)
    }

    func noMoonlightHostAnsweredAt(_ address: String) -> String {
        catalog.format("No Moonlight host answered at %@.", address)
    }

    func noAppsAvailableOn(_ host: String) -> String {
        catalog.format("No apps available on %@.", host)
    }

    func appNoLongerOn(_ app: String, _ host: String) -> String {
        catalog.format("%@ is no longer on %@. Pick another app.", app, host)
    }

    // MARK: - The Emulate picker for a Moonlight pad

    var xbox: String {
        catalog.text("Xbox")
    }

    var playStation: String {
        catalog.text("PlayStation")
    }

    var nintendo: String {
        catalog.text("Nintendo")
    }

    func dishAsksHostToPlugIn(_ host: String) -> String {
        catalog.format("Dish asks %@ to plug in this controller. Some hosts override the choice.", host)
    }
}
