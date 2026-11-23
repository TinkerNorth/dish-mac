// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

extension L10n {

    // MARK: - Contact support

    var contactSupport: String {
        catalog.text("Contact support")
    }

    var reportAProblem: String {
        catalog.text("Report a problem")
    }

    var askAQuestion: String {
        catalog.text("Ask a question")
    }

    var supportReportDetail: String {
        paragraph(
            catalog.text("Your mail app opens with your words first, then this Mac's summary, and the file attached."),
            catalog.text("Nothing is sent until you press Send.")
        )
    }

    var reportCategory: String {
        catalog.text("What it is about")
    }

    var categoryNotRecognised: String {
        catalog.text("Controller not recognised")
    }

    var categoryNoFeedback: String {
        catalog.text("No rumble or feedback")
    }

    var categoryConnection: String {
        catalog.text("Connection or latency")
    }

    var categoryOther: String {
        catalog.text("Something else")
    }

    var categoryQuestion: String {
        catalog.text("A question")
    }

    var whatHappened: String {
        catalog.text("What happened, and what did you expect?")
    }

    var reportController: String {
        catalog.text("The controller it concerns")
    }

    var notAboutAController: String {
        catalog.text("Not about a controller")
    }

    var theFileWillHold: String {
        catalog.text("The file will hold")
    }

    var holdsYourWords: String {
        catalog.text("Your words and the category you picked")
    }

    var holdsThisMac: String {
        catalog.text(
            "This Mac's model, macOS version, battery, temperature state, Wi-Fi signal strength and whether it has a USB host controller"
        )
    }

    var holdsControllers: String {
        catalog.text("Each controller's identity and record, and how much went in and came out of it")
    }

    var holdsHosts: String {
        catalog.text("Each host's version and session, under an alias, and what the host says of this connection")
    }

    var holdsLogAndCapture: String {
        catalog.text("The event log, and the capture of the controller you picked if you took one")
    }

    var reportNeverHolds: String {
        catalog.text("It never holds pairing keys, fingerprints, IP addresses, Wi-Fi names or host names.")
    }

    var previewFile: String {
        catalog.text("Preview file")
    }

    var hideFile: String {
        catalog.text("Hide file")
    }

    var continueInMail: String {
        catalog.text("Continue in Mail")
    }

    var askingHosts: String {
        catalog.text("Asking each connected host for its own view of this connection…")
    }

    // MARK: - No mail app

    var noMailApp: String {
        catalog.text("No mail app took the message.")
    }

    func fileSavedAt(_ path: String) -> String {
        catalog.format("The file is saved at %@.", path)
    }

    var fileNotSaved: String {
        catalog.text("The file was not saved.")
    }

    func messageOnTheClipboard(_ recipient: String) -> String {
        catalog.format("Your message is on the clipboard: paste it into an email to %@.", recipient)
    }

    var attachTheFile: String {
        catalog.text("Attach the file to it.")
    }
}
