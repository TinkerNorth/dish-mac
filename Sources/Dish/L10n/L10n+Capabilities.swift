// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

extension L10n {

    // MARK: - The Emulate picker

    var emulateAs: String {
        catalog.text("Emulate as")
    }

    var auto: String {
        catalog.text("Auto")
    }

    func autoSends(_ typeName: String) -> String {
        catalog.format("Auto sends %@ for this controller.", typeName)
    }

    var waitingOnTheType: String {
        catalog.text("Waiting on the type…")
    }

    func typeNumber(_ type: Int) -> String {
        catalog.format("Type %lld", type)
    }

    // MARK: - The capability table

    var whatCarries: String {
        catalog.text("What carries")
    }

    var supported: String {
        catalog.text("Supported")
    }

    var notAvailable: String {
        catalog.text("Not available")
    }

    var pending: String {
        catalog.text("Pending")
    }

    var gamepad: String {
        catalog.text("Gamepad")
    }

    var analogTriggers: String {
        catalog.text("Analog triggers")
    }

    var mouse: String {
        catalog.text("Mouse")
    }

    var adaptiveTriggers: String {
        catalog.text("Adaptive triggers")
    }

    var playerLeds: String {
        catalog.text("Player LEDs")
    }

    var microphone: String {
        catalog.text("Microphone")
    }

    var speaker: String {
        catalog.text("Speaker")
    }

    func everyLayerCarries(_ typeName: String) -> String {
        catalog.format("Every layer carries it: the pad, this Mac, the %@ type and the host.", typeName)
    }

    var switchedOffInSettings: String {
        catalog.text("Switched off in Settings.")
    }

    var waitingForTheHostsCatalog: String {
        catalog.text("Waiting for the host’s catalog and capabilities.")
    }

    func padLacks(_ feature: String) -> String {
        catalog.format("The pad has no %@.", feature)
    }

    func macDoesNotRoute(_ feature: String) -> String {
        catalog.format("Dish on a Mac doesn’t route %@.", feature)
    }

    func typeLacks(_ typeName: String, _ feature: String) -> String {
        catalog.format("%@ doesn’t carry %@.", typeName, feature)
    }

    func hostLacks(_ feature: String) -> String {
        catalog.format("The host doesn’t carry %@.", feature)
    }

    // MARK: - The motion chip

    var motionNoGyroscope: String {
        catalog.text("Motion: no gyroscope")
    }

    var motionTurnedOff: String {
        catalog.text("Motion: turned off")
    }

    var motionNotSent: String {
        catalog.text("Motion: not sent")
    }

    var motionHostCannotReceive: String {
        catalog.text("Motion: host can’t receive")
    }

    var motionServerCannotDeliver: String {
        catalog.text("Motion: server can’t deliver")
    }

    var motionStreaming: String {
        catalog.text("Motion: streaming")
    }

    // MARK: - The link tier

    var tierFastest: String {
        catalog.text("Fastest")
    }

    var tierFast: String {
        catalog.text("Fast")
    }

    var tierBasic: String {
        catalog.text("Basic")
    }

    var tierFastestHelp: String {
        catalog.text("A Satellite link: our own wire, one hop, every feature.")
    }

    var tierFastHelp: String {
        catalog.text("A Moonlight host’s control stream.")
    }

    var tierBasicHelp: String {
        catalog.text("The system’s Bluetooth gamepad layer.")
    }
}
