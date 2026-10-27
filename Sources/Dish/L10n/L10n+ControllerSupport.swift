// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// "Layout guessed", "Check the buttons" and "Help support this controller":
/// the desktops' remap words where they have them.
extension L10n {

    // MARK: - The card

    var layoutGuessed: String {
        catalog.text("Layout guessed")
    }

    var layoutGuessedHelp: String {
        catalog.text("Dish guessed how this controller’s buttons are laid out. Check the buttons to correct it.")
    }

    var moreActions: String {
        catalog.text("More actions")
    }

    var checkTheButtons: String {
        catalog.text("Check the buttons")
    }

    // MARK: - Check the buttons

    func pressTheButtonYouWantAs(_ control: String) -> String {
        catalog.format("Press the button you want as %@", control)
    }

    func pullTheTriggerYouWantAs(_ control: String) -> String {
        catalog.format("Pull the trigger you want as %@", control)
    }

    var pushTheLeftStickUp: String {
        catalog.text("Push the left stick up")
    }

    var pushTheRightStickUp: String {
        catalog.text("Push the right stick up")
    }

    func stepOf(_ step: Int, _ count: Int) -> String {
        catalog.format("Step %lld of %lld", step, count)
    }

    var everyControlIsChecked: String {
        catalog.text("Every control is checked.")
    }

    var checkAgain: String {
        catalog.text("Check again")
    }

    var storedForThisModel: String {
        catalog.text("Stored for this controller model — applies on the next report, no re-attach.")
    }

    var notRemappable: String {
        catalog.text("Not remappable")
    }

    var notRemappableBody: String {
        catalog.text("This controller uses its built-in mapping and can’t be remapped here.")
    }

    var connectTheControllerToCheck: String {
        catalog.text("Connect the controller to check its buttons.")
    }

    var invertLeftStickY: String {
        catalog.text("Invert left stick Y")
    }

    var invertRightStickY: String {
        catalog.text("Invert right stick Y")
    }

    func sourceButton(_ index: Int) -> String {
        catalog.format("Button %lld", index)
    }

    func sourceHat(_ index: Int) -> String {
        catalog.format("Hat %lld", index)
    }

    func sourceAnalogAxis(_ index: Int) -> String {
        catalog.format("Axis %lld · analog", index)
    }

    func sourceDigitalButton(_ index: Int) -> String {
        catalog.format("Button %lld · digital", index)
    }

    var unassigned: String {
        catalog.text("Unassigned")
    }

    // MARK: - Help support this controller

    var helpSupportIntro: String {
        catalog.text("Dish records what this controller sends as you press each control. Nothing leaves this Mac unless you paste it.")
    }

    var lookingForTheController: String {
        catalog.text("Looking for the controller. Make sure it is connected.")
    }

    var unknownSupportDevice: String {
        catalog.text("Dish can’t tell which device this is.")
    }

    func reportsSeen(_ count: Int) -> String {
        catalog.format("Reports seen: %lld", count)
    }

    var openAGitHubIssue: String {
        catalog.text("Open a GitHub issue")
    }

    var pasteTheReportIntoTheIssue: String {
        catalog.text("Copy the report, then paste it into the issue.")
    }

    var stepAtRest: String {
        catalog.text("Leave the controller untouched")
    }

    var stepPressA: String {
        catalog.text("Press A")
    }

    var stepPressB: String {
        catalog.text("Press B")
    }

    var stepPressX: String {
        catalog.text("Press X")
    }

    var stepPressY: String {
        catalog.text("Press Y")
    }

    var stepLeftShoulder: String {
        catalog.text("Press the left shoulder button")
    }

    var stepRightShoulder: String {
        catalog.text("Press the right shoulder button")
    }

    var stepLeftTrigger: String {
        catalog.text("Pull the left trigger")
    }

    var stepRightTrigger: String {
        catalog.text("Pull the right trigger")
    }

    var stepSelect: String {
        catalog.text("Press Select")
    }

    var stepStart: String {
        catalog.text("Press Start")
    }

    var stepDpadUp: String {
        catalog.text("Press up on the d-pad")
    }

    var stepLeftStickUp: String {
        catalog.text("Move the left stick up")
    }

    var stepRightStickUp: String {
        catalog.text("Move the right stick up")
    }
}
