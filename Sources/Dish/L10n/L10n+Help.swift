// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// Help & FAQ, the desktops' HelpScreen word for word: the host PC keeps
/// its tray, so no answer needed a Mac word of its own.
extension L10n {

    var helpSubline: String {
        catalog.text("How Dish works, and what to try when it doesn’t")
    }

    var walkMeThroughSetup: String {
        catalog.text("Walk me through setup")
    }

    var viewSourceOnGithub: String {
        catalog.text("View source on GitHub")
    }

    // MARK: - Sections

    var conceptsSection: String {
        catalog.text("CONCEPTS")
    }

    var bestPerformanceSection: String {
        catalog.text("BEST PERFORMANCE")
    }

    var troubleshootingSection: String {
        catalog.text("TROUBLESHOOTING")
    }

    var aboutDishSection: String {
        catalog.text("ABOUT DISH")
    }

    var linksSection: String {
        catalog.text("LINKS")
    }

    // MARK: - Concepts

    var whatIsDish: String {
        catalog.text("What is Dish?")
    }

    var whatIsDishAnswer: String {
        paragraph(
            catalog.text("Dish turns a controller plugged into this PC into a wireless gamepad for another PC."),
            catalog.text("It forwards input over your local network to the free Satellite helper.")
        )
    }

    var whatIsSatellite: String {
        catalog.text("What is Satellite?")
    }

    var whatIsSatelliteAnswer: String {
        paragraph(
            catalog.text("Satellite is a small, free, open-source program that runs on the host PC."),
            catalog.text("It receives input from Dish over Wi-Fi and presents itself to that PC’s games as a regular controller."),
            catalog.text("Without Satellite, games can’t see your controller."),
            catalog.text("Install it from dish.tinkernorth.com/downloads/satellite.")
        )
    }

    var whatsMotionAndTheTouchpad: String {
        catalog.text("What’s motion and what’s the touchpad?")
    }

    var whatsMotionAnswer: String {
        paragraph(
            catalog.text("Motion is a controller’s gyroscope used as aim assist, forwarded as the gyro inside a PlayStation pad."),
            catalog.text("The touchpad forwards a DualSense / DualShock 4 touchpad."),
            catalog.text("Both need a PlayStation-style controller and a Satellite connection.")
        )
    }

    // MARK: - Best performance

    var bestSetupForLowLatency: String {
        catalog.text("What’s the best setup for low latency?")
    }

    var bestSetupAnswer: String {
        paragraph(
            catalog.text("Both PCs on the same router, wired Ethernet where you can, 5 GHz Wi-Fi otherwise."),
            catalog.text("Dish needs this PC and the host PC on the same local network —"),
            catalog.text("it sends input as small UDP packets, so a fast LAN keeps the delay tiny.")
        )
    }

    var isWiredBetter: String {
        catalog.text("Is wired better than wireless?")
    }

    var isWiredBetterAnswer: String {
        paragraph(
            catalog.text("For the controller-to-PC leg, a USB controller has no radio latency."),
            catalog.text("For the PC-to-PC leg, connect both machines to the router with Ethernet if you can.")
        )
    }

    // MARK: - Troubleshooting

    var cantFindSatellites: String {
        catalog.text("Dish can’t find any satellites. What now?")
    }

    var cantFindSatellitesAnswer: String {
        paragraph(
            catalog.text("Check that Satellite is running on the host PC (its tray icon should be visible)."),
            catalog.text("Confirm both PCs are on the same network."),
            catalog.text("Guest networks and 2.4 GHz vs 5 GHz on the same router count as different."),
            catalog.text("Click Scan in Connections to retry.")
        )
    }

    var pinKeepsGettingRejected: String {
        catalog.text("My PIN keeps getting rejected.")
    }

    var pinRejectedAnswer: String {
        let shown = catalog.text(
            "The PIN is shown by Satellite on the host PC and changes if you restart it."
        )
        let check = catalog.text(
            "Check the digits right before you type, and make sure you’re pairing with the right Satellite if more than one is listed."
        )
        return paragraph(shown, check)
    }

    var keepsDisconnecting: String {
        catalog.text("My controller keeps disconnecting mid-game.")
    }

    var keepsDisconnectingAnswer: String {
        paragraph(
            catalog.text("Most disconnects come from Wi-Fi switching bands or the controller’s own wireless dropping."),
            catalog.text("Prefer wired Ethernet on both PCs and a wired controller."),
            catalog.text("Dish keeps the session alive while the app is open.")
        )
    }

    var motionIsntWorking: String {
        catalog.text("Motion (gyro aim) isn’t working.")
    }

    var motionIsntWorkingAnswer: String {
        let needs = catalog.text(
            "Motion needs three things: a Satellite connection, a controller with a gyroscope (DualSense, DualShock 4, Switch Pro),"
        )
        let type = catalog.text(
            "and a PlayStation-style controller type on the slot."
        )
        let fix = catalog.text(
            "Switch the emulated type to PlayStation to enable the motion channel."
        )
        return paragraph(needs, type, fix)
    }

    // MARK: - About Dish

    var isDishOpenSource: String {
        catalog.text("Is Dish open source?")
    }

    var isDishOpenSourceAnswer: String {
        let yes = catalog.text(
            "Yes."
        )
        let licence = catalog.text(
            "Dish (Windows, Android, Linux, Mac) and Satellite are all released under LGPL-3.0, source on GitHub at github.com/TinkerNorth."
        )
        let welcome = catalog.text(
            "Pull requests welcome."
        )
        return paragraph(yes, licence, welcome)
    }

    var whatDoesDishCollect: String {
        catalog.text("What does Dish collect?")
    }

    var whatDoesDishCollectAnswer: String {
        paragraph(
            catalog.text("Almost nothing."),
            catalog.text("Dish doesn’t send gameplay or controller input anywhere except the host PC on your local network."),
            catalog.text("Anonymous crash reports are on by default and can be turned off (Settings → Diagnostics)."),
            catalog.text("See the privacy policy for the full list.")
        )
    }
}
