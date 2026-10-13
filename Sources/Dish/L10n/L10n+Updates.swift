// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

extension L10n {

    // MARK: - Updates

    var updatesSection: String {
        catalog.text("UPDATES")
    }

    var checkForUpdates: String {
        catalog.text("Check for updates")
    }

    var checkForUpdatesAutomatically: String {
        catalog.text("Check for updates automatically")
    }

    var checkForUpdatesDetail: String {
        catalog.text("Dish asks GitHub for the newest release at startup and every few hours. See the privacy policy for what is sent.")
    }

    var updatePrivacyFootnote: String {
        catalog.text("Checking connects to github.com and sends no account data.")
    }

    var openReleasePage: String {
        catalog.text("Open release page")
    }

    var skipThisVersion: String {
        catalog.text("Skip this version")
    }

    var checkingForUpdates: String {
        catalog.text("Checking for updates…")
    }

    var onLatestVersion: String {
        catalog.text("You're on the latest version.")
    }

    var noUpdateInformation: String {
        catalog.text("No update information yet.")
    }

    var updateOffline: String {
        catalog.text("You're offline. Dish will retry automatically.")
    }

    var updateManifestInvalid: String {
        catalog.text("The release information didn't parse. Dish will retry automatically.")
    }

    var updateCheckFailed: String {
        catalog.text("The update check failed. Dish will retry automatically.")
    }

    var updateChecksOff: String {
        catalog.text("Automatic update checks are off.")
    }

    var never: String {
        catalog.text("never")
    }

    var versionUnsupported: String {
        catalog.text("This version of Dish is no longer supported. Please update.")
    }

    func updateAvailable(_ version: String) -> String {
        catalog.format("Dish %@ is available.", version)
    }

    func lastChecked(_ version: String, _ when: String) -> String {
        catalog.format("Dish %@ · last checked %@", version, when)
    }

    func updateAvailableToast(_ version: String) -> String {
        catalog.format("Update available: Dish %@. See Settings for the release.", version)
    }

    // MARK: - About

    var aboutSection: String {
        catalog.text("ABOUT")
    }

    var helpAndFaq: String {
        catalog.text("Help & FAQ")
    }

    var helpDetail: String {
        catalog.text("Concepts, performance tips, and troubleshooting.")
    }

    var supportDish: String {
        catalog.text("Support Dish")
    }

    var supportDetail: String {
        catalog.text("Donate via GitHub Sponsors, Ko-fi, or Buy Me a Coffee.")
    }

    var privacyPolicy: String {
        catalog.text("Privacy policy")
    }

    var openSourceLicenses: String {
        catalog.text("Open source licenses")
    }

    var licensesDetail: String {
        catalog.text("Dish uses no third-party code. SwiftFormat and SwiftLint are build-time tools under the MIT license.")
    }

    func aboutLine(_ version: String) -> String {
        catalog.format("Dish %@ · TinkerNorth · LGPL-3.0", version)
    }
}
