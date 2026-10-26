// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import Foundation
import SwiftUI

/// One fact of a Diagnostics card: the key in the left column, the value
/// beside it.
struct FactLine: Equatable, Identifiable {
    let key: String
    let value: String

    var id: String {
        key
    }
}

// MARK: - A host

/// The card's lines by the host's kind: a satellite's session, or a Moonlight
/// host's. Bluetooth hosts reach no card here.
func hostLines(_ host: HostDiagnostics, locale: Locale = .current, words: L10n = .app) -> [FactLine] {
    switch host.summary.kind {
    case .moonlight: moonlightHostLines(host, locale: locale, words: words)
    case .satellite, .bluetooth: satelliteHostLines(host, locale: locale, words: words)
    }
}

func satelliteHostLines(_ host: HostDiagnostics, locale: Locale = .current, words: L10n = .app) -> [FactLine] {
    let facts = host.facts
    let opening = [FactLine(key: words.address, value: connectionAddressLine(host.summary))]
        + (facts.compat == .unknown && !facts.live ? [] : [FactLine(key: words.protocolKey, value: protocolText(facts, words: words))])
    guard facts.live else { return opening + [FactLine(key: words.session, value: words.noSessionRightNow)] }
    return opening + [
        FactLine(key: words.epoch, value: epochText(facts, words: words)),
        FactLine(key: words.controllers, value: controllersText(facts, words: words)),
        FactLine(key: words.virtualControllers, value: backendText(facts, words: words)),
        FactLine(key: words.roundTrip, value: roundTripText(facts.latency, locale: locale, words: words)),
        FactLine(key: words.missedHeartbeats, value: String(facts.missedAcks)),
        FactLine(key: words.mouseControl, value: facts.mouseControlGranted ? words.granted : words.notGranted),
        FactLine(key: words.controllerAudio, value: hostAudioText(facts.audio, words: words))
    ]
}

/// What the probe granted of the pad's own audio, lane by lane.
func hostAudioText(_ audio: HostAudioVerdict, words: L10n = .app) -> String {
    let granted = [(audio.mic, words.microphone), (audio.speaker, words.speaker), (audio.hapticAudio, words.hapticAudio)]
    let names = granted.filter(\.0).map(\.1)
    return names.isEmpty ? words.notGranted : names.joined(separator: " · ")
}

/// The settled version, the offer when it differed, and the standing when
/// the chip would show one.
func protocolText(_ facts: HostSessionFacts, words: L10n = .app) -> String {
    let settled = words.protocolVersion(facts.settledProtocol)
    let version = facts.offeredProtocol == facts.settledProtocol ? settled : words.protocolOffered(settled, facts.offeredProtocol)
    guard let standing = protocolCompatText(facts.compat, words: words) else { return version }
    return "\(version) · \(standing)"
}

func agreementText(_ agreement: Agreement, words: L10n = .app) -> String {
    switch agreement {
    case .inStep: words.inStep
    case .diverged: words.outOfStep
    case .unknown: words.waitingForTheFirstHeartbeat
    }
}

func epochText(_ facts: HostSessionFacts, words: L10n = .app) -> String {
    let agreement = agreementText(epochAgreement(hostEpoch: facts.hostEpoch, appliedEpoch: facts.appliedEpoch), words: words)
    guard let host = facts.hostEpoch else { return "\(words.epochApplied(facts.appliedEpoch)) · \(agreement)" }
    return "\(words.epochOnHostAndApplied(host, facts.appliedEpoch)) · \(agreement)"
}

func indexListText(_ indices: [Int], words: L10n = .app) -> String {
    indices.isEmpty ? words.none : indices.map(String.init).joined(separator: ", ")
}

func controllersText(_ facts: HostSessionFacts, words: L10n = .app) -> String {
    let confirmed = indexListText(bitmapIndices(facts.confirmedBitmap), words: words)
    let agreement = agreementText(bitmapAgreement(hostBitmap: facts.hostBitmap, confirmedBitmap: facts.confirmedBitmap), words: words)
    guard let hostBitmap = facts.hostBitmap else { return "\(words.controllersConfirmed(confirmed)) · \(agreement)" }
    let onHost = indexListText(bitmapIndices(hostBitmap), words: words)
    return "\(words.controllersOnHostAndConfirmed(onHost, confirmed)) · \(agreement)"
}

func backendText(_ facts: HostSessionFacts, words: L10n = .app) -> String {
    let word = switch hostBackendOf(facts.backendAvailable) {
    case .available: words.available
    case .unavailable: words.unavailable
    case .unknown: words.unknown
    }
    guard let active = facts.activeControllers else { return word }
    return "\(word) · \(words.inUse(active))"
}

/// "12.3 ms" in the locale's digits and separator; the unit is the SI symbol.
func millisecondsText(_ ms: Double, locale: Locale) -> String {
    String(format: "%.1f ms", locale: locale, ms)
}

func roundTripText(_ latency: LatencySummary, locale: Locale = .current, words: L10n = .app) -> String {
    guard latency.samples > 0, let p50 = latency.p50RttMs, let p99 = latency.p99RttMs else { return words.noSamplesYet }
    let figures = words.roundTripFigures(
        millisecondsText(p50, locale: locale),
        millisecondsText(p99, locale: locale),
        millisecondsText(p50 / 2, locale: locale)
    )
    return "\(figures) · \(words.pingsOf(latency.samples, latency.capacity))"
}

// MARK: - A Moonlight host

/// The address, the session's standing, what the host said of itself, the
/// app running, the control link's round trip, and a line per pad the host
/// holds; a host nothing opened this run reads idle on its probe alone.
func moonlightHostLines(_ host: HostDiagnostics, locale: Locale = .current, words: L10n = .app) -> [FactLine] {
    let facts = host.moonlight ?? .resting(info: nil)
    var lines = [
        FactLine(key: words.address, value: connectionAddressLine(host.summary)),
        FactLine(key: words.session, value: moonlightPhaseText(facts.phase, summary: host.summary, words: words))
    ]
    if let info = facts.info {
        if !info.hostname.isEmpty { lines.append(FactLine(key: words.hostName, value: info.hostname)) }
        if let version = info.appVersion, !version.isEmpty { lines.append(FactLine(key: words.hostApp, value: version)) }
        if let version = info.gfeVersion, !version.isEmpty { lines.append(FactLine(key: words.gfeVersion, value: version)) }
        lines.append(FactLine(key: words.runningApp, value: moonlightRunningAppText(facts, info: info, words: words)))
    }
    lines.append(FactLine(key: words.controlRoundTrip, value: moonlightRoundTripText(facts.controlRoundTripMs, words: words)))
    return lines + facts.pads.map { pad in FactLine(key: words.padNumber(Int(pad.number)), value: moonlightPadText(pad, words: words)) }
}

/// Idle, launching and live as Android's Diagnostics names them; a failure
/// in the words the host card already uses for it.
func moonlightPhaseText(_ phase: MoonlightSessionPhase, summary: ConnectionSummary, words: L10n = .app) -> String {
    switch phase {
    case .idle: words.sessionIdle
    case .checkingInfo, .launching, .rtsp, .controlConnecting: words.sessionLaunching
    case .streaming: words.sessionLive
    case .failed: moonlightStatusLine(summary, phase: phase, words: words) ?? words.sessionEnded
    }
}

/// The app our session settled on; else the host's own current game, by its
/// id, since the host names no title in /serverinfo; else none.
func moonlightRunningAppText(_ facts: MoonlightHostDiagnostics, info: MoonlightServerInfo, words: L10n = .app) -> String {
    if let app = facts.appName, !app.isEmpty { return app }
    return info.currentGame == 0 ? words.none : String(info.currentGame)
}

func moonlightRoundTripText(_ ms: Int64?, words: L10n = .app) -> String {
    ms.map { words.wholeMilliseconds(Int($0)) } ?? words.unknown
}

/// The slot the pad belongs to, the type it was plugged in as, and the reports sent on it.
func moonlightPadText(_ pad: MoonlightPadFacts, words: L10n = .app) -> String {
    "\(pad.slotId) · \(moonlightTypeName(pad.type, words: words)) · \(words.reportsCount(pad.reports))"
}

// MARK: - A controller

func padLines(_ pad: PadDiagnostics, words: L10n = .app) -> [FactLine] {
    let slot = pad.slot
    let opening = [FactLine(key: words.connection, value: words.gameControllerFramework)]
        + (pad.hardwareId.map { [FactLine(key: words.usbId, value: hardwareIdText($0))] } ?? [])
        + [FactLine(key: words.backgroundInput, value: backgroundInputText(pad.backgroundInput, words: words))]
        + (slot.emulation.map { [FactLine(key: words.type, value: emulatedTypeName($0, words: words))] } ?? [])
        + (slot.battery.map { [FactLine(key: words.battery, value: batteryHelp($0, words: words))] } ?? [])
    return opening + bindingLines(pad, words: words) + audioLines(pad, words: words)
}

/// Whether the pad keeps reaching the host while another app is in front.
func backgroundInputText(_ on: Bool, words: L10n = .app) -> String {
    on ? words.on : words.off
}

/// The pad's own audio: where its route stands and, once the engine has a
/// plan for it, what the microphone, the speaker and the haptics lanes are
/// doing. A family without audio has no lines.
func audioLines(_ pad: PadDiagnostics, words: L10n = .app) -> [FactLine] {
    guard let audio = pad.audio, let route = audio.route, route.verdict != .familyWithoutAudio else { return [] }
    let opening = [FactLine(key: words.controllerAudio, value: audioRouteText(route, words: words))]
    guard let state = audio.state else { return opening }
    let counters = audio.counters ?? AudioCounters()
    let speaker = laneText(state.plan.speakerVoice, played: counters.speakerPlayed, concealed: counters.speakerConcealed, words: words)
    let haptics = laneText(state.plan.hapticVoice, played: counters.hapticPlayed, concealed: counters.hapticConcealed, words: words)
    return opening + [
        FactLine(key: words.microphone, value: micStateText(state.plan, sent: counters.micSent, words: words)),
        FactLine(key: words.speaker, value: speaker),
        FactLine(key: words.haptics, value: haptics),
        FactLine(key: words.micLamp, value: micLampText(state.micLed, words: words))
    ]
}

/// The device the pad's audio rides, or why it rides none.
func audioRouteText(_ route: PadAudioRoute, words: L10n = .app) -> String {
    switch route.verdict {
    case .routed: route.function.map(\.device.name) ?? words.nothing
    case .noAudioFunction: words.noUsbAudioFunction
    case .padNameShared: words.twoControllersShareOneName
    case .endpointNameShared: words.moreThanOneAudioDevice
    case .familyWithoutAudio: words.nothing
    }
}

func micStateText(_ plan: AudioPlan, sent: Int, words: L10n = .app) -> String {
    guard plan.micArmed else { return words.offWord }
    guard plan.capture else { return words.armedMuted }
    return "\(words.capturing) · \(words.framesSent(sent))"
}

func laneText(_ voice: Bool, played: Int, concealed: Int, words: L10n = .app) -> String {
    voice ? "\(words.playing) · \(words.playedAndConcealed(played, concealed))" : words.idle
}

func micLampText(_ state: MicLedState?, words: L10n = .app) -> String {
    switch state {
    case .on: words.on
    case .pulse: words.pulse
    case .off, nil: words.off
    }
}

/// The wire side is a satellite's: what the descriptor declared and what the
/// host said back.
func bindingLines(_ pad: PadDiagnostics, words: L10n = .app) -> [FactLine] {
    guard let bound = pad.slot.boundStatus else { return [FactLine(key: words.binding, value: words.notBound)] }
    let binding = FactLine(key: words.binding, value: "\(connectionTitle(bound)) · \(words.satellite)")
    guard let wire = pad.wire else { return [binding, FactLine(key: words.onTheWire, value: words.notDeclaredToTheHostYet)] }
    return [
        binding,
        FactLine(key: words.controllerIndex, value: String(wire.controllerIndex)),
        FactLine(key: words.confirmedByHost, value: wire.confirmed ? words.yes : words.no),
        FactLine(key: words.streaming, value: streamingText(wire.streaming, words: words)),
        FactLine(key: words.advertised, value: advertisedText(wire.caps, words: words)),
        FactLine(key: words.touchpadOnTheWire, value: wireTouchpadText(wire.touchpad, words: words))
    ]
}

func streamingText(_ streaming: Streaming, words: L10n = .app) -> String {
    switch streaming {
    case .yes: words.yes
    case .no: words.no
    case .unknown: words.waitingForTheFirstHeartbeat
    }
}

func wireCapText(_ cap: WireCap, words: L10n = .app) -> String {
    switch cap {
    case .analogTriggers: words.analogTriggers
    case .rumble: words.rumble
    case .motion: words.motion
    case .lightbar: words.lightBar
    case .triggerEffects: words.adaptiveTriggers
    case .playerLeds: words.playerLeds
    case .mic: words.microphone
    case .speaker: words.speaker
    case .hapticAudio: words.hapticAudio
    }
}

func advertisedText(_ caps: UInt16, words: L10n = .app) -> String {
    let names = advertisedCaps(caps).map { wireCapText($0, words: words) }
    return names.isEmpty ? words.nothing : names.joined(separator: " · ")
}

func wireTouchpadText(_ touchpad: WireTouchpad, words: L10n = .app) -> String {
    switch touchpad {
    case .off: words.offWord
    case .pad: words.padWord
    case .mouse: words.mouseWord
    }
}

// MARK: - The events

func eventText(_ event: DiagnosticsEvent, words: L10n = .app) -> String {
    switch event.kind {
    case .linkAppeared: words.eventLinkAppeared(event.subject, linkStateText(event.to, words: words))
    case .linkChanged: words.eventLinkChanged(event.subject, linkStateText(event.from, words: words), linkStateText(event.to, words: words))
    case .linkRemoved: words.eventLinkRemoved(event.subject)
    case .padAttached: words.eventPadAttached(event.subject)
    case .padDetached: words.eventPadDetached(event.subject)
    case .padBound: words.eventPadBound(event.subject, event.host)
    case .padUnbound: words.eventPadUnbound(event.subject, event.host)
    }
}

/// The wall-clock time of a line in the locale's medium time style.
func eventTimeText(_ atMs: Int64, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = timeZone
    formatter.dateStyle = .none
    formatter.timeStyle = .medium
    return formatter.string(from: Date(timeIntervalSince1970: Double(atMs) / 1000))
}

func eventLine(_ event: DiagnosticsEvent, locale: Locale = .current, timeZone: TimeZone = .current, words: L10n = .app) -> String {
    "\(eventTimeText(event.atMs, locale: locale, timeZone: timeZone))  \(eventText(event, words: words))"
}

/// The whole log, oldest first, for the clipboard.
func eventsTranscript(
    _ events: [DiagnosticsEvent],
    locale: Locale = .current,
    timeZone: TimeZone = .current,
    words: L10n = .app
) -> String {
    events.map { eventLine($0, locale: locale, timeZone: timeZone, words: words) }.joined(separator: "\n")
}

/// The newest `limit` lines, newest first, as the window shows them.
func recentEvents(_ events: [DiagnosticsEvent], limit: Int = 30) -> [DiagnosticsEvent] {
    Array(events.suffix(limit).reversed())
}

// MARK: - The page

/// Everything Diagnostics draws: a card per host and per pad, or the word
/// for none, the game devices GameController leaves out, and the flight
/// recorder's newest lines.
struct DiagnosticsPageState: Equatable {
    let hosts: DiagnosticsCards
    let pads: DiagnosticsCards
    /// Nil while GameController claims every game device.
    let otherDevices: OtherInputDevicesState?
    /// The newest lines, newest first.
    let events: [DiagnosticsEventLine]
    /// Copy waits until the recorder holds a line.
    let canCopy: Bool
}

enum DiagnosticsCards: Equatable {
    case empty(String)
    case cards([DiagnosticsCardState])
}

/// One card: a headline with its dot and chip, then one fact per line.
struct DiagnosticsCardState: Equatable, Identifiable {
    let id: String
    let title: String
    let dot: Color?
    let chip: String?
    let lines: [FactLine]
    /// The pad Inspect input opens; nil on a host's card.
    let inspects: String?
}

struct DiagnosticsEventLine: Equatable, Identifiable {
    let id: Int
    let text: String
}

func diagnosticsPageState(
    facts: ShellFacts,
    locale: Locale = .current,
    timeZone: TimeZone = .current,
    words: L10n = .app
) -> DiagnosticsPageState {
    let hosts = facts.diagnostics.hosts.map { hostCard($0, locale: locale, words: words) }
    let pads = facts.diagnostics.pads.map { padCard($0, words: words) }
    let events = recentEvents(facts.diagnosticsEvents).map { event in
        DiagnosticsEventLine(id: event.id, text: eventLine(event, locale: locale, timeZone: timeZone, words: words))
    }
    return DiagnosticsPageState(
        hosts: hosts.isEmpty ? .empty(words.noSatellitesYet) : .cards(hosts),
        pads: pads.isEmpty ? .empty(words.noControllersConnected) : .cards(pads),
        otherDevices: otherInputDevicesState(facts.diagnostics.inputDevices, words: words),
        events: events,
        canCopy: !facts.diagnosticsEvents.isEmpty
    )
}

func hostCard(_ host: HostDiagnostics, locale: Locale = .current, words: L10n = .app) -> DiagnosticsCardState {
    DiagnosticsCardState(
        id: host.id,
        title: connectionTitle(host.summary),
        dot: linkDotColor(host.summary.live),
        chip: linkStateText(host.summary.live, words: words),
        lines: hostLines(host, locale: locale, words: words),
        inspects: nil
    )
}

func padCard(_ pad: PadDiagnostics, words: L10n = .app) -> DiagnosticsCardState {
    DiagnosticsCardState(id: pad.id, title: pad.slot.name, dot: nil, chip: nil, lines: padLines(pad, words: words), inspects: pad.slot.id)
}

/// The whole log for the clipboard, oldest first.
func diagnosticsTranscript(facts: ShellFacts, locale: Locale = .current, timeZone: TimeZone = .current, words: L10n = .app) -> String {
    eventsTranscript(facts.diagnosticsEvents, locale: locale, timeZone: timeZone, words: words)
}
