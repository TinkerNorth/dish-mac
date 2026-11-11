// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// A pad's input path, as its card, Home, the inspector and Diagnostics word it.
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

    var reasonDishCouldNotRead: String {
        catalog.text("Dish couldn’t read it directly, so macOS reads it")
    }

    // MARK: - A card's path and its check

    func playerNumber(_ number: Int) -> String {
        catalog.format("Player %lld", number)
    }

    var pressAnyButtonOnThisController: String {
        catalog.text("Press any button on this controller")
    }

    var notResponding: String {
        catalog.text("Not responding?")
    }

    func pressANow(_ secondsLeft: Int) -> String {
        catalog.format("Press A now · %lld s", secondsLeft)
    }

    var checkRespondsThroughMacOS: String {
        catalog.text("It responds through macOS")
    }

    var checkRespondsReadDirectly: String {
        catalog.text("It responds when Dish reads it directly")
    }

    var checkNothingDishCanRead: String {
        catalog.text("Nothing arrived, and Dish can’t read this controller yet")
    }

    var checkNothingArrived: String {
        catalog.text("Nothing arrived from this controller")
    }

    var useDirect: String {
        catalog.text("Use Direct")
    }

    var helpSupportThisController: String {
        catalog.text("Help support this controller")
    }

    var connectionHint: String {
        catalog.text("Check the cable or the Bluetooth connection, then try again")
    }

    // MARK: - An offer to read a pad directly

    var dishCanReadThisControllerDirectly: String {
        catalog.text("Dish can read this controller directly.")
    }

    var whileItDoesItsKeyboardAndMouseAreOff: String {
        catalog.text("While it does, the controller’s keyboard and mouse are off.")
    }

    var macOSAsksForInputMonitoringFirst: String {
        catalog.text("macOS asks for Input Monitoring first, because the controller also acts as a keyboard.")
    }

    var macOSHasNotLetDishReadIt: String {
        catalog.text("macOS has not let Dish read this controller.")
    }

    var allowDishUnderInputMonitoring: String {
        catalog.text("Allow Dish under Privacy & Security › Input Monitoring, then quit and reopen Dish.")
    }

    var dishCouldNotOpenThisController: String {
        catalog.text("Dish couldn’t open this controller; another app may be using it.")
    }

    var quitThatAppOrPlugItBackIn: String {
        catalog.text("Quit that app, or unplug the controller and plug it back in.")
    }

    var dishIsReadingThisReceiverDirectly: String {
        catalog.text("Dish is reading this receiver directly.")
    }

    var turnOnAControllerPairedWithIt: String {
        catalog.text("Turn on a controller paired with it.")
    }

    var stopReadingDirectly: String {
        catalog.text("Stop reading directly")
    }

    // MARK: - Drops

    var playerWord: String {
        catalog.text("Player")
    }

    var disconnects: String {
        catalog.text("Disconnects")
    }

    var padKeepsDropping: String {
        catalog.text("Keeps disconnecting")
    }

    func padKeepsDisconnecting(_ name: String) -> String {
        catalog.format("%@ keeps disconnecting", name)
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
