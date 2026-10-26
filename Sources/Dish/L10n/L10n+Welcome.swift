// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// The first-run welcome, the desktops' WelcomeScreen word for word.
extension L10n {

    // MARK: - Page 1

    var welcomeEyebrow: String {
        catalog.text("Welcome")
    }

    var yourControllerOnYourPc: String {
        catalog.text("Your controller, on your PC")
    }

    var welcomeIntro: String {
        let forwards = catalog.text(
            "Dish forwards a real game controller plugged into this PC to another PC running Satellite, over your local network."
        )
        let ready = catalog.text(
            "Plug in a pad and it shows up ready to play."
        )
        return paragraph(forwards, ready)
    }

    // MARK: - Page 2

    var howItWorks: String {
        catalog.text("How it works")
    }

    var aShortHopOverWifi: String {
        catalog.text("A short hop over Wi-Fi")
    }

    var howItWorksBody: String {
        let travel = catalog.text(
            "Your controller’s button presses, sticks, and motion travel to a small free helper called Satellite running on the host PC."
        )
        return paragraph(
            travel,
            catalog.text("Satellite shows up to its games as a regular gamepad."),
            catalog.text("No extra setup per game.")
        )
    }

    // MARK: - Page 3

    var oneMoreThing: String {
        catalog.text("One more thing")
    }

    var installSatelliteOnTheHostPc: String {
        catalog.text("Install Satellite on the host PC")
    }

    var installSatelliteBody: String {
        paragraph(
            catalog.text("Satellite is free and open source."),
            catalog.text("Grab it from dish.tinkernorth.com, run the installer, and Dish will find it automatically."),
            catalog.text("You can finish this intro now and install Satellite later.")
        )
    }

    var openDownloadPage: String {
        catalog.text("Open download page")
    }

    // MARK: - Page 4

    var youreSet: String {
        catalog.text("You’re set")
    }

    var readyWhenYouAre: String {
        catalog.text("Ready when you are")
    }

    var youreSetBody: String {
        paragraph(
            catalog.text("Finish walks you through input, destination and binding — about a minute."),
            catalog.text("You can also skip and do it later from Set up in the rail.")
        )
    }

    // MARK: - The bar

    var skip: String {
        catalog.text("Skip")
    }

    var next: String {
        catalog.text("Next")
    }

    var finish: String {
        catalog.text("Finish")
    }
}
