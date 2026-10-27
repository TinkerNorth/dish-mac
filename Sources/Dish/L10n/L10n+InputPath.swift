// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// A pad's input path, as Diagnostics words it.
extension L10n {

    // MARK: - A controller's lines

    var inputPath: String {
        catalog.text("Input path")
    }

    var standardPath: String {
        catalog.text("Standard")
    }

    var directPath: String {
        catalog.text("Direct")
    }

    var pathReason: String {
        catalog.text("Reason")
    }

    var hidReports: String {
        catalog.text("HID reports")
    }

    var reportsFromThePad: String {
        catalog.text("Reports from the pad")
    }

    func hertz(_ hz: Int) -> String {
        catalog.format("%lld Hz", hz)
    }

    // MARK: - Why a path

    var reasonDirectByModel: String {
        catalog.text("Dish reads this model itself")
    }

    var reasonMacOSCannotRead: String {
        catalog.text("macOS does not read it, so Dish does")
    }

    var reasonMacOSReads: String {
        catalog.text("macOS reads it")
    }

    var reasonUserPicked: String {
        catalog.text("Your pick")
    }

    // MARK: - A check's verdict

    var verdictStandardWorks: String {
        catalog.text("macOS passes its input")
    }

    var verdictDishReadsIt: String {
        catalog.text("Dish reads its input")
    }

    var verdictNoDecoder: String {
        catalog.text("no input Dish can decode")
    }

    var verdictNothingAtAll: String {
        catalog.text("no input at all")
    }

    // MARK: - The events

    func eventPadPathChosen(_ subject: String, _ path: String, _ reason: String) -> String {
        catalog.format("%@: input path %@ (%@)", subject, path, reason)
    }

    func eventPadCheckConcluded(_ subject: String, _ verdict: String) -> String {
        catalog.format("%@: check found %@", subject, verdict)
    }

    func eventPadKeepsDisconnecting(_ subject: String) -> String {
        catalog.format("%@: keeps disconnecting", subject)
    }
}
