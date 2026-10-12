// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

extension L10n {

    // MARK: - Connection failures

    var identityChanged: String {
        catalog.text("This satellite's security identity changed. If it was reinstalled, forget it here and pair again.")
    }

    var protocolMismatch: String {
        catalog.text("This app and the satellite speak different protocol versions. Update both to the latest version.")
    }

    var approvalDeclined: String {
        catalog.text("The satellite declined the pairing request.")
    }

    var approvalTimedOut: String {
        catalog.text("No response from the satellite. The pairing request timed out.")
    }

    var repairNeeded: String {
        catalog.text("This satellite no longer recognizes this device. Re-pair needed.")
    }

    var noSharedKey: String {
        catalog.text("No shared key — re-pair needed")
    }

    var connectionFailed: String {
        catalog.text("connection failed")
    }

    var badSessionMaterial: String {
        catalog.text("Bad token from server")
    }

    var sessionLinkFailed: String {
        catalog.text("The satellite accepted, but the controller link would not open. Try again.")
    }

    var controllerNotApplied: String {
        catalog.text("Server could not apply the controller")
    }

    var noServersFound: String {
        catalog.text("No servers found — check your network")
    }

    var pairingFailed: String {
        catalog.text("Pairing failed")
    }

    func unreachable(_ detail: String) -> String {
        catalog.format("Server unreachable — has it moved networks? (%@)", detail)
    }

    func errorDetail(_ detail: String) -> String {
        catalog.format("Error: %@", detail)
    }
}
