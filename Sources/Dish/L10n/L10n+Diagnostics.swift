// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

extension L10n {

    // MARK: - The window

    var diagnostics: String {
        catalog.text("Diagnostics")
    }

    var diagnosticsDetail: String {
        catalog.text("Each host's session, each controller down to the wire, and a log of what changed.")
    }

    var hosts: String {
        catalog.text("Hosts")
    }

    var controllers: String {
        catalog.text("Controllers")
    }

    var events: String {
        catalog.text("Events")
    }

    var noSatellitesYet: String {
        catalog.text("No satellites yet. Pair one on the Connections page and its session shows here.")
    }

    var copy: String {
        catalog.text("Copy")
    }

    var eventsCopied: String {
        catalog.text("Events copied.")
    }

    // MARK: - A host's lines

    var address: String {
        catalog.text("Address")
    }

    var protocolKey: String {
        catalog.text("Protocol")
    }

    func protocolVersion(_ version: Int) -> String {
        catalog.format("v%lld", version)
    }

    func protocolOffered(_ settled: String, _ offered: Int) -> String {
        catalog.format("%@ (offered v%lld)", settled, offered)
    }

    var session: String {
        catalog.text("Session")
    }

    var noSessionRightNow: String {
        catalog.text("No session right now")
    }

    var epoch: String {
        catalog.text("Epoch")
    }

    func epochApplied(_ applied: Int) -> String {
        catalog.format("applied: %lld", applied)
    }

    func epochOnHostAndApplied(_ host: Int, _ applied: Int) -> String {
        catalog.format("on the host: %lld · applied: %lld", host, applied)
    }

    var inStep: String {
        catalog.text("in step")
    }

    var outOfStep: String {
        catalog.text("out of step")
    }

    var waitingForTheFirstHeartbeat: String {
        catalog.text("waiting for the first heartbeat")
    }

    func controllersConfirmed(_ confirmed: String) -> String {
        catalog.format("confirmed: %@", confirmed)
    }

    func controllersOnHostAndConfirmed(_ host: String, _ confirmed: String) -> String {
        catalog.format("on the host: %@ · confirmed: %@", host, confirmed)
    }

    var none: String {
        catalog.text("none")
    }

    var virtualControllers: String {
        catalog.text("Virtual controllers")
    }

    var available: String {
        catalog.text("available")
    }

    var unavailable: String {
        catalog.text("unavailable")
    }

    var unknown: String {
        catalog.text("unknown")
    }

    func inUse(_ count: Int) -> String {
        catalog.format("%lld in use", count)
    }

    var roundTrip: String {
        catalog.text("Round trip")
    }

    // MARK: - A Moonlight host's card

    var sessionIdle: String {
        catalog.text("Idle")
    }

    var sessionLaunching: String {
        catalog.text("Launching")
    }

    var sessionLive: String {
        catalog.text("Live")
    }

    var sessionEnded: String {
        catalog.text("Ended")
    }

    var hostName: String {
        catalog.text("Host name")
    }

    var hostApp: String {
        catalog.text("Host app")
    }

    var gfeVersion: String {
        catalog.text("GFE version")
    }

    var runningApp: String {
        catalog.text("Running app")
    }

    var controlRoundTrip: String {
        catalog.text("Control round trip")
    }

    func padNumber(_ number: Int) -> String {
        catalog.format("Pad %lld", number)
    }

    func wholeMilliseconds(_ ms: Int) -> String {
        catalog.format("%lld ms", ms)
    }

    func reportsCount(_ count: Int) -> String {
        catalog.format("%lld reports", count)
    }

    var noSamplesYet: String {
        catalog.text("no samples yet")
    }

    func roundTripFigures(_ p50: String, _ p99: String, _ oneWay: String) -> String {
        catalog.format("%@ p50 · %@ p99 · %@ one way", p50, p99, oneWay)
    }

    func pingsOf(_ samples: Int, _ capacity: Int) -> String {
        catalog.format("%lld of %lld pings", samples, capacity)
    }

    var missedHeartbeats: String {
        catalog.text("Missed heartbeats")
    }

    var mouseControl: String {
        catalog.text("Mouse control")
    }

    var granted: String {
        catalog.text("granted")
    }

    var notGranted: String {
        catalog.text("not granted")
    }

    // MARK: - A controller's lines

    var connection: String {
        catalog.text("Connection")
    }

    var gameControllerFramework: String {
        catalog.text("GameController")
    }

    var type: String {
        catalog.text("Type")
    }

    var battery: String {
        catalog.text("Battery")
    }

    var binding: String {
        catalog.text("Binding")
    }

    var notBound: String {
        catalog.text("Not bound")
    }

    var satellite: String {
        catalog.text("Satellite")
    }

    var onTheWire: String {
        catalog.text("On the wire")
    }

    var notDeclaredToTheHostYet: String {
        catalog.text("Not declared to the host yet")
    }

    var controllerIndex: String {
        catalog.text("Controller index")
    }

    var confirmedByHost: String {
        catalog.text("Confirmed by host")
    }

    var yes: String {
        catalog.text("yes")
    }

    var no: String {
        catalog.text("no")
    }

    var streaming: String {
        catalog.text("Streaming")
    }

    var advertised: String {
        catalog.text("Advertised")
    }

    var nothing: String {
        catalog.text("nothing")
    }

    var touchpadOnTheWire: String {
        catalog.text("Touchpad on the wire")
    }

    var padWord: String {
        catalog.text("pad")
    }

    var mouseWord: String {
        catalog.text("mouse")
    }

    var offWord: String {
        catalog.text("off")
    }

    var hapticAudio: String {
        catalog.text("Haptic audio")
    }

    // MARK: - The events

    func eventLinkAppeared(_ subject: String, _ state: String) -> String {
        catalog.format("%@: appeared, %@", subject, state)
    }

    func eventLinkChanged(_ subject: String, _ from: String, _ to: String) -> String {
        catalog.format("%@: %@ → %@", subject, from, to)
    }

    func eventLinkRemoved(_ subject: String) -> String {
        catalog.format("%@: removed", subject)
    }

    func eventPadAttached(_ subject: String) -> String {
        catalog.format("%@: attached", subject)
    }

    func eventPadDetached(_ subject: String) -> String {
        catalog.format("%@: detached", subject)
    }

    func eventPadBound(_ subject: String, _ host: String) -> String {
        catalog.format("%@: bound to %@", subject, host)
    }

    func eventPadUnbound(_ subject: String, _ host: String) -> String {
        catalog.format("%@: unbound from %@", subject, host)
    }

    // MARK: - The crash report

    var crashReport: String {
        catalog.text("Crash report")
    }

    var crashLogLeft: String {
        catalog.text("An earlier run left a crash log.")
    }

    var review: String {
        catalog.text("Review")
    }

    var crashReportIntro: String {
        catalog.text(
            "Dish closed unexpectedly last time. The report below has had your home folder, network addresses and key-like values removed."
        )
    }

    var reportOnGitHub: String {
        catalog.text("Report on GitHub")
    }

    var discard: String {
        catalog.text("Discard")
    }

    var reportCopied: String {
        catalog.text("Report copied.")
    }
}
