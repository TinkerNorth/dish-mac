// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// The setup walk and its ways in, the desktops' SetupWizardPage and its
/// steps word for word; the Local Network prompt's card is Android's
/// explain-then-ask pattern in macOS's words.
extension L10n {

    // MARK: - The ways in

    var setUp: String {
        catalog.text("Set up")
    }

    var setUpDish: String {
        catalog.text("Set up Dish")
    }

    var setUpDishChevron: String {
        catalog.text("Set up Dish ›")
    }

    var setupFillsThisDiagramIn: String {
        catalog.text("Setup fills this diagram in, one answer at a time — and hands it back finished.")
    }

    var setupAndHelpSection: String {
        catalog.text("Setup & help")
    }

    var setUpDishDetail: String {
        catalog.text("Walk through input, destination and binding. Re-run any time.")
    }

    // MARK: - The frame

    var nothingIsChangedUntilTheLastStep: String {
        catalog.text("Nothing is changed until the last step")
    }

    var backChevron: String {
        catalog.text("‹ Back")
    }

    var continueChevron: String {
        catalog.text("Continue ›")
    }

    var stepInput: String {
        catalog.text("Step 1 of 3 · Input")
    }

    var stepDestination: String {
        catalog.text("Step 2 of 3 · Destination")
    }

    var stepType: String {
        catalog.text("Step 3 of 3 · Type")
    }

    var stepSession: String {
        catalog.text("Step 3 of 3 · Session")
    }

    var stepFeel: String {
        catalog.text("Step 3 of 3 · Feel")
    }

    var stepReview: String {
        catalog.text("Step 3 of 3 · Review")
    }

    var leaveSetup: String {
        catalog.text("Leave setup?")
    }

    var nothingHasBeenSentYet: String {
        catalog.text("Nothing has been sent yet. Your answers will be discarded.")
    }

    var keepSettingUp: String {
        catalog.text("Keep setting up")
    }

    // MARK: - Input

    var whichController: String {
        catalog.text("Which controller?")
    }

    var eachIsDrawnAsItsNode: String {
        catalog.text("Each is drawn as the node it will become on Home, with what it can carry beside it.")
    }

    var plugYourControllerIn: String {
        catalog.text("Plug your controller in")
    }

    var plugYourControllerInBody: String {
        paragraph(
            catalog.text("Into any USB port, or turn on a pad already paired to this machine."),
            catalog.text("The system sees it, and it appears here — there is no list to add it to.")
        )
    }

    // MARK: - Destination

    var whichPc: String {
        catalog.text("Which PC?")
    }

    var pickThePcThisControllerShouldDrive: String {
        catalog.text("Pick the PC this controller should drive.")
    }

    var scanningYourWifiForASatellite: String {
        catalog.text("Scanning your Wi-Fi for a Satellite host.")
    }

    var noPcsFoundYet: String {
        catalog.text("No PCs found yet")
    }

    var aPcShowsUpHere: String {
        catalog.text("A PC shows up here once the free Satellite app is running on it and both machines are on the same network.")
    }

    var dontSeeYourPc: String {
        catalog.text("Don’t see your PC? Install the free Satellite app on it.")
    }

    var rescan: String {
        catalog.text("Rescan")
    }

    var pairingIsOneTime: String {
        catalog.text("Pairing is one-time. After this, Dish reconnects to it by itself.")
    }

    // MARK: - Explaining the Local Network prompt

    var macosWillAskForTheNetwork: String {
        catalog.text("macOS will ask to let Dish find satellites on your network")
    }

    var allowLocalNetworkToScan: String {
        catalog.text("Dish finds and connects to satellites on your Wi-Fi. Allow local network access to scan.")
    }

    var showMeThePrompt: String {
        catalog.text("Show me the prompt")
    }

    var openSystemSettings: String {
        catalog.text("Open System Settings")
    }

    // MARK: - Type, Session, Feel

    var howShouldThePcSeeIt: String {
        catalog.text("How should the PC see it?")
    }

    var howShouldTheHostSeeIt: String {
        catalog.text("How should the host see it?")
    }

    var pickTheControllerThePcShouldReport: String {
        catalog.text("Pick the controller the PC should report. Each unlocks different extras — this pad limits all three the same way.")
    }

    func dishAsksTheHostToPlugIn(_ host: String) -> String {
        catalog.format("Dish asks %@ to plug in this controller. Some hosts override the choice.", host)
    }

    var howShouldItFeel: String {
        catalog.text("How should it feel?")
    }

    var onlyTheExtrasBothSupport: String {
        catalog.text("Only the extras your input and destination both support are shown.")
    }

    var nothingHereIsSavedYet: String {
        catalog.text("Nothing here is saved yet. Everything travels with the bind on the next step.")
    }

    // MARK: - Review

    var reviewAndBind: String {
        catalog.text("Review and bind")
    }

    var everythingAboveIsDecided: String {
        catalog.text("Everything above is decided. Bind draws the wire for real.")
    }

    func nothingOnTheHostHasChangedYet(_ host: String) -> String {
        catalog.format("Nothing on %@ has changed yet. Bind is the first and only write.", host)
    }

    // MARK: - The blockers

    var connectionLost: String {
        catalog.text("Connection lost")
    }

    func stoppedResponding(_ host: String) -> String {
        catalog.format("%@ stopped responding. Input isn’t getting through. It may be asleep or off your network.", host)
    }

    var controllerUnplugged: String {
        catalog.text("Controller unplugged")
    }

    var holdingTheBinding: String {
        catalog.text("Holding the binding so you can reconnect. Re-plug to keep configuring, or close this screen.")
    }

    var startOver: String {
        catalog.text("Start over")
    }

    var exit: String {
        catalog.text("Exit")
    }
}
