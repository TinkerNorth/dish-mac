// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

extension L10n {

    // MARK: - Connections sheet

    var connections: String {
        catalog.text("Connections")
    }

    var scan: String {
        catalog.text("Scan")
    }

    var scanning: String {
        catalog.text("Scanning…")
    }

    var done: String {
        catalog.text("Done")
    }

    var wifiServersSection: String {
        catalog.text("WI-FI SERVERS")
    }

    var pressScanHint: String {
        catalog.text("Press Scan to look for servers on your LAN")
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

    func foundVia(_ source: String) -> String {
        catalog.format("Found · %@", source)
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

    // MARK: - Pairing sheet

    var enterPin: String {
        catalog.text("Enter the 4-digit PIN shown on the Satellite server.")
    }

    var pin: String {
        catalog.text("PIN")
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
}
