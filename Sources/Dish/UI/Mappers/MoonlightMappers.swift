// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import Foundation
import SwiftUI

// MARK: - The Connections page's two sections

/// The satellites' rows; the Moonlight hosts sit under their own header.
func satelliteSummaries(_ connections: [ConnectionSummary]) -> [ConnectionSummary] {
    connections.filter { $0.kind == .satellite }
}

/// A row of the Moonlight section: a host the records or the pool know, or
/// one a scan found that they do not.
enum MoonlightRow: Equatable {
    case known(ConnectionSummary)
    case discovered(MoonlightHost)

    var key: String {
        switch self {
        case let .known(summary): summary.id
        case let .discovered(host): host.id
        }
    }
}

/// Known hosts first, then the discovered ones not already among them.
func moonlightRows(known: [ConnectionSummary], discovered: [MoonlightHost]) -> [MoonlightRow] {
    let hosts = known.filter { $0.kind == .moonlight }
    let knownIds = Set(hosts.map(\.id))
    return hosts.map(MoonlightRow.known) + discovered.filter { !knownIds.contains($0.id) }.map(MoonlightRow.discovered)
}

/// A host's display name: its advertised name, or its address when it has none.
func moonlightHostTitle(_ host: MoonlightHost) -> String {
    host.name.isEmpty ? host.address : host.name
}

/// The address line, numeric and untranslated, with the protocol's name.
func moonlightHostDetail(_ host: MoonlightHost) -> String {
    "\(host.address) • Moonlight"
}

func moonlightDiscoveredStatusText(words: L10n = .app) -> String {
    words.foundVia(words.moonlightHost)
}

/// The trust word beside a host: the records hold a pairing unless the chip
/// says Needs pairing.
func moonlightTrustText(_ summary: ConnectionSummary, words: L10n = .app) -> String {
    summary.live == .stale ? words.notPaired : words.pairedTrust
}

func moonlightTrustColor(_ summary: ConnectionSummary) -> Color {
    summary.live == .stale ? DishTheme.muted : DishTheme.success
}

/// How many controllers the host carries; nothing while none is bound.
func moonlightControllersText(_ summary: ConnectionSummary, words: L10n = .app) -> String? {
    summary.boundSlotIds.isEmpty ? nil : words.controllersOnHost(summary.boundSlotIds.count)
}

// MARK: - A host's actions and status

/// What a host's row offers besides Forget.
enum MoonlightRowAction: Equatable {
    case pair
    case rePair
    case disconnect
    case reconnect
    case startSession
    case retry
    case quitApp
}

/// Pairing while trust is missing (again when the records held one), the
/// session's way out of where it stands, and nothing while the bindings
/// drive it or a session is coming up.
func moonlightRowActions(_ summary: ConnectionSummary, phase: MoonlightSessionPhase?) -> [MoonlightRowAction] {
    switch phase {
    case .streaming: [.disconnect]
    case .checkingInfo, .launching, .rtsp, .controlConnecting: []
    case .failed(.dropped): [.reconnect]
    case .failed(.hostEnded): [.startSession]
    case .failed(.appAlreadyRunning), .failed(.resumeFailed): [.quitApp, .retry]
    case .failed(.launchRejected), .failed(.rtspRejected), .failed(.controlLost), .failed(.noApps), .failed(.appRemoved),
         .failed(.unreachable): [.retry]
    case .failed(.trustLost), .failed(.hostReplaced): [.rePair]
    case .failed(.notPaired): [.pair]
    case .idle, nil: summary.live == .stale ? [.pair] : []
    }
}

func moonlightActionText(_ action: MoonlightRowAction, host: String, words: L10n = .app) -> String {
    switch action {
    case .pair: words.pairNow
    case .rePair: words.rePair
    case .disconnect: words.disconnect
    case .reconnect: words.reconnect
    case .startSession: words.startASession
    case .retry: words.retry
    case .quitApp: words.closeTheAppOn(host)
    }
}

/// The line under the chip: why the session is not up, when the chip alone
/// does not say; nil while the chip says it all.
func moonlightStatusLine(_ summary: ConnectionSummary, phase: MoonlightSessionPhase?, words: L10n = .app) -> String? {
    let host = summary.label
    switch phase {
    case .failed(.notPaired): return words.notPairedYet
    case .failed(.trustLost): return words.noLongerRecognises(host)
    case .failed(.hostReplaced): return words.wasReset(host)
    case .failed(.unreachable): return words.isNotAnswering(host)
    case .failed(.dropped): return words.sessionOnHostEnded(host)
    case .failed(.hostEnded): return words.hostEndedTheSession(host)
    case .failed(.appAlreadyRunning): return words.anotherDeviceIsUsing(host)
    case .failed(.resumeFailed): return words.couldNotRejoin(host)
    case .failed(.launchRejected): return words.refusedTheSessionNoReason(host)
    case .failed(.rtspRejected), .failed(.controlLost): return words.couldNotFinishTheSession(host)
    case .failed(.noApps): return words.noAppsOnThisHost
    case .failed(.appRemoved), .checkingInfo, .launching, .rtsp, .controlConnecting, .streaming: return nil
    case .idle, nil: return summary.live == .stale ? words.notPairedYet : nil
    }
}

// MARK: - The Emulate picker of a Moonlight pad

/// Auto, then the three types the host protocol names, in its numbering.
func moonlightEmulateOptions(words: L10n = .app) -> [EmulateOption] {
    [
        EmulateOption(id: nil, label: words.auto),
        EmulateOption(id: Int(MoonlightControllerType.xbox), label: words.xbox),
        EmulateOption(id: Int(MoonlightControllerType.playStation), label: words.playStation),
        EmulateOption(id: Int(MoonlightControllerType.nintendo), label: words.nintendo)
    ]
}

/// The protocol's type names; anything else a host plugs in as an Xbox pad.
func moonlightTypeName(_ type: UInt8, words: L10n = .app) -> String {
    switch type {
    case MoonlightControllerType.playStation: words.playStation
    case MoonlightControllerType.nintendo: words.nintendo
    default: words.xbox
    }
}

/// Under the picker: what Auto sends for this pad, or what a pick asks of the host.
func moonlightEmulateDetail(_ slot: ControllerSlot, words: L10n = .app) -> String {
    guard let emulation = slot.emulation, let host = slot.boundStatus?.label else { return words.waitingOnTheType }
    if emulation.isOverride { return words.dishAsksHostToPlugIn(host) }
    let resolved = MoonlightPadRules.resolveType(
        picked: UInt8(truncatingIfNeeded: emulation.type),
        sourceHasMotion: slot.capabilities.hasMotion
    )
    return words.autoSends(moonlightTypeName(resolved, words: words))
}

/// The Emulate picker for a bound slot, by the kind of host it is bound to:
/// a satellite offers its catalog, a Moonlight host the protocol's three types.
func emulatePicker(for slot: ControllerSlot, _ emulation: SlotEmulation, words: L10n = .app) -> (options: [EmulateOption], detail: String) {
    if slot.boundStatus?.kind == .moonlight {
        return (moonlightEmulateOptions(words: words), moonlightEmulateDetail(slot, words: words))
    }
    return (emulateOptions(emulation, words: words), emulateDetail(emulation, words: words))
}

// MARK: - What a host's events say

/// A host's event as a banner: its severity and words, and the host whose
/// app a tap closes when the way out is to close it.
struct MoonlightNotice: Equatable {
    let severity: DishNotification.Severity
    let title: String
    var body: String?
    var quitHost: MoonlightHost?
    let key: String
}

/// The PIN is a sheet, not a banner; every other event is worded here.
func moonlightNotice(for event: MoonlightConnectionEvent, words: L10n = .app) -> MoonlightNotice? {
    switch event {
    case .pairingPinReady:
        return nil
    case let .paired(host):
        return MoonlightNotice(
            severity: .success,
            title: words.pairedWithHost(moonlightHostTitle(host)),
            body: words.pairedBody,
            key: "moonlight.pair"
        )
    case let .pairingFailed(host, reason):
        return MoonlightNotice(
            severity: .error,
            title: words.didNotAcceptThePin(moonlightHostTitle(host)),
            body: pairingFailureBody(reason, words: words),
            key: "moonlight.pair"
        )
    case let .hostReplaced(host):
        return hostNotice(.warn, host, words.wasReset(moonlightHostTitle(host)), words.newIdentityBody)
    case let .appAlreadyRunning(host, _):
        let name = moonlightHostTitle(host)
        return hostNotice(.warn, host, words.anotherDeviceIsUsing(name), words.runningAnAppForAnotherDevice(name), quit: true)
    case let .rejoinRefused(host):
        let name = moonlightHostTitle(host)
        return hostNotice(.warn, host, words.couldNotRejoin(name), words.hostWouldNotHandItBack(name), quit: true)
    case let .launchRefused(host, message):
        let name = moonlightHostTitle(host)
        let title = message.isEmpty ? words.refusedTheSessionNoReason(name) : words.refusedTheSession(name, message)
        return hostNotice(.error, host, title, words.addTheControllerAnyway)
    case let .setupFailed(host):
        return hostNotice(.error, host, words.couldNotFinishTheSession(moonlightHostTitle(host)), words.theStreamDidNotComeUp)
    case let .hostFull(host):
        let name = moonlightHostTitle(host)
        return hostNotice(.warn, host, words.hostIsFull(name), words.fourControllersAtMost(name))
    case let .endedByHost(host):
        return hostNotice(.info, host, words.hostEndedTheSession(moonlightHostTitle(host)), words.theAppClosedOnTheHost)
    case let .appCloseRequested(host):
        return hostNotice(.info, host, words.askedToCloseTheApp(moonlightHostTitle(host)), nil)
    case let .noHostAnswered(address):
        return MoonlightNotice(severity: .error, title: words.noMoonlightHostAnsweredAt(address), key: "moonlight.add")
    case let .noAppsAvailable(host):
        return hostNotice(.warn, host, words.noAppsAvailableOn(moonlightHostTitle(host)), nil)
    case let .appRemoved(host, appName):
        return hostNotice(.warn, host, words.appNoLongerOn(appName, moonlightHostTitle(host)), nil)
    }
}

/// Which step gave up, in the host's words when it had any; a wrong PIN or a
/// forged host reads the same, as neither is this device's to fix differently.
private func pairingFailureBody(_ reason: MoonlightPairingFailure, words: L10n) -> String {
    switch reason.kind {
    case .noIdentity: words.noPairingIdentityYet
    case .noCertificate, .noChallengeResponse, .noPairingSecret, .hostNotAuthentic, .notConfirmed:
        reason.hostSaid.isEmpty ? words.checkTheCodeWentIntoTheRightHost : reason.hostSaid
    }
}

/// One banner per host: a newer word about the same host replaces the last.
private func hostNotice(
    _ severity: DishNotification.Severity,
    _ host: MoonlightHost,
    _ title: String,
    _ body: String?,
    quit: Bool = false
) -> MoonlightNotice {
    MoonlightNotice(severity: severity, title: title, body: body, quitHost: quit ? host : nil, key: "moonlight.\(host.id)")
}
