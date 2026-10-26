// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

extension L10n {

    // MARK: - Connections page

    var connections: String {
        catalog.text("Connections")
    }

    var scan: String {
        catalog.text("Scan")
    }

    var scanning: String {
        catalog.text("Scanning…")
    }

    var scanAgain: String {
        catalog.text("Scan again")
    }

    var lookingForSatellites: String {
        catalog.text("Looking for satellites")
    }

    var scanningOverMdnsAndBroadcast: String {
        catalog.text("Scanning your network over mDNS and UDP broadcast. Hosts appear here as they answer.")
    }

    var noSatellitesFound: String {
        catalog.text("No satellites found")
    }

    var satelliteShowsUpHere: String {
        catalog.text("A PC shows up here once the free Satellite app is running on it and both machines are on the same network.")
    }

    var getSatellite: String {
        catalog.text("Get Satellite ↗")
    }

    var pairEllipsis: String {
        catalog.text("Pair…")
    }

    var moonlightHosts: String {
        catalog.text("Moonlight hosts")
    }

    var streamToASunshinePc: String {
        catalog.text("Stream to a PC running Sunshine, Apollo or Wolf instead of a satellite.")
    }

    var nothingPairedYet: String {
        catalog.text("Nothing paired yet")
    }

    var pairASatelliteAndDishSavesIt: String {
        catalog.text("Pair a satellite and Dish saves it here for next time.")
    }

    var carrying: String {
        catalog.text("Carrying")
    }

    var nothingBoundYet: String {
        catalog.text("Nothing bound yet")
    }

    /// A manifest line: the pad, and the type the binding emulates it as.
    func padAsType(_ pad: String, _ type: String) -> String {
        catalog.format("%@ — as %@", pad, type)
    }

    func moreActionsFor(_ name: String) -> String {
        catalog.format("More actions for %@", name)
    }

    var addByAddressPlaceholder: String {
        catalog.text("Add by IP — e.g. 192.168.1.50 or 192.168.1.50:9876")
    }

    var add: String {
        catalog.text("Add")
    }

    var invalidAddress: String {
        catalog.text("Enter an IPv4 address like 192.168.1.50 (optionally :port)")
    }

    var forget: String {
        catalog.text("Forget")
    }

    var connect: String {
        catalog.text("Connect")
    }

    var disconnect: String {
        catalog.text("Disconnect")
    }

    var connecting: String {
        catalog.text("Connecting…")
    }

    var pairing: String {
        catalog.text("Pairing…")
    }

    // MARK: - Forget asks first

    func forgetQuestion(_ name: String) -> String {
        catalog.format("Forget %@?", name)
    }

    var pairingKeyIsDeleted: String {
        catalog.text("Its pairing key is deleted — you’ll need the PIN again.")
    }

    func bindingsRideOnIt(_ count: Int) -> String {
        catalog.format("%lld bindings ride on it and will be dropped:", count)
    }
}

extension L10n {

    // MARK: - Link state chips

    var found: String {
        catalog.text("Found")
    }

    var needsPairing: String {
        catalog.text("Needs pairing")
    }

    var offline: String {
        catalog.text("Offline")
    }

    var ready: String {
        catalog.text("Ready")
    }

    var online: String {
        catalog.text("Online")
    }

    var unsteady: String {
        catalog.text("Unsteady")
    }

    // MARK: - Protocol chip

    var satelliteUpdateRecommended: String {
        catalog.text("Satellite update recommended")
    }

    var satelliteUpdateRequiredChip: String {
        catalog.text("Satellite update required")
    }

    var dishUpdateRequiredChip: String {
        catalog.text("Dish update required")
    }
}

extension L10n {

    // MARK: - Discovery sources

    var udpBroadcast: String {
        catalog.text("UDP broadcast")
    }

    var mdns: String {
        catalog.text("mDNS")
    }

    var mdnsAndBroadcast: String {
        catalog.text("mDNS + broadcast")
    }

    var addedByAddress: String {
        catalog.text("added by address")
    }
}

extension L10n {

    // MARK: - Pairing card

    var enterSatellitePin: String {
        catalog.text("Enter the 4-digit PIN shown on the Satellite’s screen.")
    }

    var pairingPinField: String {
        catalog.text("Pairing PIN, 4 digits")
    }

    var cancel: String {
        catalog.text("Cancel")
    }

    var pair: String {
        catalog.text("Pair")
    }

    func pairWith(_ name: String) -> String {
        catalog.format("Pair with %@", name)
    }

    var orWord: String {
        catalog.text("or")
    }

    func typePinOnSatellite(_ name: String) -> String {
        catalog.format("Type this PIN on %@ to approve the pairing.", name)
    }

    var waitingForApproval: String {
        catalog.text("Waiting for approval on the satellite…")
    }

    var approvedConnecting: String {
        catalog.text("Approved — connecting…")
    }

    var operatorDeclined: String {
        catalog.text("The operator declined the pairing.")
    }

    var noApprovalCodeExpired: String {
        catalog.text("No approval — the code expired.")
    }

    var aboutTwoMinutes: String {
        catalog.text("~2 min")
    }

    func differentSatelliteVersion(_ name: String) -> String {
        catalog.format("%@ is running a different Satellite version. Update both, then pair again.", name)
    }

    func couldNotReach(_ name: String) -> String {
        catalog.format("Couldn’t reach %@. Make sure it’s on and on your network.", name)
    }

    func notApprovedYet(_ name: String) -> String {
        catalog.format("%@ hasn’t approved the pairing yet.", name)
    }

    func pinNotAccepted(_ name: String) -> String {
        catalog.format("That PIN wasn’t accepted. Check the code on %@ and try again.", name)
    }

    var codeChangesOnRefresh: String {
        catalog.text("The code changes if the Satellite screen was refreshed.")
    }
}
