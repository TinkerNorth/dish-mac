// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

extension L10n {

    /// The language the catalog chose, for the controller data's own words.
    var language: String {
        catalog.locale.identifier
    }

    // MARK: - The controller database

    var controllerDatabase: String {
        catalog.text("Controller database")
    }

    /// The privacy policy's own label for the switch, in every language.
    var checkForControllerUpdatesAutomatically: String {
        catalog.text("Check for controller updates automatically")
    }

    /// The privacy policy's own label for the action.
    var checkNow: String {
        catalog.text("Check now")
    }

    var controllerUpdatesDetail: String {
        paragraph(
            catalog.text("Dish asks dish.tinkernorth.com for a newer list of controllers ten seconds after launch and every six hours."),
            catalog.text("Off, nothing is sent.")
        )
    }

    func controllerDbBundled(_ version: Int) -> String {
        catalog.format("Version %lld, bundled with Dish", version)
    }

    func controllerDbDownloaded(_ version: Int) -> String {
        catalog.format("Version %lld, downloaded", version)
    }

    var neverChecked: String {
        catalog.text("Never checked")
    }

    func lastCheckAt(_ time: String, _ result: String) -> String {
        catalog.format("Last check %@: %@", time, result)
    }

    var upToDate: String {
        catalog.text("Up to date")
    }

    var updated: String {
        catalog.text("Updated")
    }

    var downloadDidNotVerify: String {
        catalog.text("The download did not verify")
    }

    var checksAreOff: String {
        catalog.text("Checks are off")
    }

    var checking: String {
        catalog.text("Checking…")
    }

    var bundledVersion: String {
        catalog.text("Bundled version")
    }

    var versionInUse: String {
        catalog.text("Version in use")
    }

    var lastCheck: String {
        catalog.text("Last check")
    }

    // MARK: - A controller's record

    var record: String {
        catalog.text("Record")
    }

    var listedAs: String {
        catalog.text("Listed as")
    }

    var verified: String {
        catalog.text("Verified")
    }

    var flagged: String {
        catalog.text("Flagged")
    }

    var hardwareCheck: String {
        catalog.text("Hardware check")
    }

    var asExpected: String {
        catalog.text("As expected")
    }

    var lastWrite: String {
        catalog.text("Last write")
    }

    var noneYet: String {
        catalog.text("None yet")
    }

    func writeWent(_ report: String, _ route: String, _ time: String) -> String {
        catalog.format("Report %@ via %@ went through at %@", report, route, time)
    }

    func writeRefused(_ report: String, _ route: String, _ time: String, _ error: String) -> String {
        catalog.format("Report %@ via %@ was refused at %@: %@", report, route, time, error)
    }

    var interruptOut: String {
        catalog.text("interrupt OUT")
    }

    var setReport: String {
        catalog.text("SET_REPORT")
    }

    var knownIssue: String {
        catalog.text("Known issue")
    }

    // MARK: - Diagnostics by email

    var emailDiagnostics: String {
        catalog.text("Email diagnostics")
    }

    var saveDiagnostics: String {
        catalog.text("Save diagnostics")
    }

    var emailDiagnosticsDetail: String {
        paragraph(catalog.text("Your mail app opens with the file attached."), catalog.text("Nothing is sent until you press Send."))
    }

    func diagnosticsMailSubject(_ version: String, _ model: String) -> String {
        catalog.format("Dish diagnostics: Dish for macOS %@ on %@", version, model)
    }

    var diagnosticsAttachmentSentence: String {
        catalog.text(
            "The attached file holds this summary in detail, and never pairing keys, fingerprints, IP addresses, Wi-Fi names or host names."
        )
    }

    var diagnosticsFileFailed: String {
        catalog.text("Dish could not write the diagnostics file.")
    }

    // MARK: - Did it work?

    var didItWork: String {
        catalog.text("Did it work?")
    }

    func didTestWork(_ test: String) -> String {
        catalog.format("%@: did it work?", test)
    }

    var itWorked: String {
        catalog.text("It worked")
    }

    var itDidNotWork: String {
        catalog.text("It didn't work")
    }

    var outcomesHint: String {
        paragraph(catalog.text("Run a test above, then say whether it worked."), catalog.text("The answers ride the diagnostics file."))
    }

    var testTone: String {
        catalog.text("Test tone")
    }

    var driftTest: String {
        catalog.text("Drift test")
    }

    var rangeTest: String {
        catalog.text("Range test")
    }

    func answeredTest(_ test: String, _ answer: String) -> String {
        catalog.format("%@ · %@", test, answer)
    }
}
