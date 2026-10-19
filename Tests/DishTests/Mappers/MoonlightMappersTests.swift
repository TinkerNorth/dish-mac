// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import DishEngine
import XCTest
@testable import Dish

/// The Moonlight words: the sheet's two sections, a host's trust, status,
/// actions and controllers, the Emulate picker of a Moonlight pad, and what
/// each of the hosts' events says.
final class MoonlightMappersTests: XCTestCase {

    private let host = MoonlightHost(name: "PC", address: "10.0.0.5", uniqueId: "abc")

    private func summary(_ live: LinkState, bound: [String] = [], label: String = "PC") -> ConnectionSummary {
        ConnectionSummary(
            id: "moonlight:10.0.0.5",
            label: label,
            detail: "10.0.0.5 • Moonlight",
            live: live,
            boundSlotId: bound.first,
            kind: .moonlight,
            boundSlotIds: bound
        )
    }

    private func satellite() -> ConnectionSummary {
        ConnectionSummary(id: "mid:1", label: "Desk", detail: "", live: .ready, boundSlotId: nil)
    }

    func testTheSheetSplitsTheKindsAndListsDiscoveredHostsAfterTheKnown() {
        let known = [satellite(), summary(.ready)]
        XCTAssertEqual(satelliteSummaries(known).map(\.id), ["mid:1"])
        let other = MoonlightHost(name: "", address: "10.0.0.9")
        let rows = moonlightRows(known: known, discovered: [host, other])
        XCTAssertEqual(rows, [.known(summary(.ready)), .discovered(other)], "a discovered host the records know is not listed twice")
        XCTAssertEqual(rows.map(\.key), ["moonlight:10.0.0.5", "moonlight:10.0.0.9"])
        XCTAssertEqual(moonlightHostTitle(other), "10.0.0.9", "a host with no name is shown by its address")
        XCTAssertEqual(moonlightHostDetail(host), "10.0.0.5 • Moonlight")
        XCTAssertEqual(moonlightDiscoveredStatusText(), "Found · Moonlight host")
    }

    func testTheTrustWordTheControllerCountAndTheChipColour() {
        XCTAssertEqual(moonlightTrustText(summary(.ready)), "Paired")
        XCTAssertEqual(moonlightTrustText(summary(.saved)), "Paired", "the records hold a pairing, proved or not")
        XCTAssertEqual(moonlightTrustText(summary(.stale)), "Not paired")
        XCTAssertEqual(moonlightTrustColor(summary(.stale)), DishTheme.muted)
        XCTAssertEqual(moonlightTrustColor(summary(.connected)), DishTheme.success)
        XCTAssertNil(moonlightControllersText(summary(.ready)))
        XCTAssertEqual(moonlightControllersText(summary(.ready, bound: ["a"])), "1 controller")
        XCTAssertEqual(moonlightControllersText(summary(.connected, bound: ["a", "b", "c"])), "3 controllers")
    }

    func testTheRowOffersTheWayOutOfWhereTheSessionStands() {
        XCTAssertEqual(moonlightRowActions(summary(.connected), phase: .streaming), [.disconnect])
        XCTAssertEqual(moonlightRowActions(summary(.connecting), phase: .launching), [], "a session coming up is left alone")
        XCTAssertEqual(moonlightRowActions(summary(.unstable), phase: .failed(.dropped)), [.reconnect])
        XCTAssertEqual(moonlightRowActions(summary(.ready), phase: .failed(.hostEnded)), [.startSession])
        XCTAssertEqual(moonlightRowActions(summary(.ready), phase: .failed(.appAlreadyRunning)), [.quitApp, .retry])
        XCTAssertEqual(moonlightRowActions(summary(.ready), phase: .failed(.resumeFailed)), [.quitApp, .retry])
        XCTAssertEqual(moonlightRowActions(summary(.ready), phase: .failed(.launchRejected)), [.retry])
        XCTAssertEqual(moonlightRowActions(summary(.saved), phase: .failed(.unreachable)), [.retry])
        XCTAssertEqual(moonlightRowActions(summary(.stale), phase: .failed(.trustLost)), [.rePair])
        XCTAssertEqual(moonlightRowActions(summary(.stale), phase: .failed(.hostReplaced)), [.rePair])
        XCTAssertEqual(moonlightRowActions(summary(.stale), phase: .failed(.notPaired)), [.pair])
        XCTAssertEqual(moonlightRowActions(summary(.stale), phase: nil), [.pair], "never paired: Pair now")
        XCTAssertEqual(moonlightRowActions(summary(.ready), phase: nil), [], "the bindings drive a paired host")
        XCTAssertEqual(moonlightRowActions(summary(.saved), phase: .idle), [])
        XCTAssertEqual(moonlightActionText(.quitApp, host: "PC"), "Close the app on PC")
        XCTAssertEqual(moonlightActionText(.pair, host: "PC"), "Pair now")
        XCTAssertEqual(moonlightActionText(.rePair, host: "PC"), "Re-pair")
        XCTAssertEqual(moonlightActionText(.disconnect, host: "PC"), "Disconnect")
        XCTAssertEqual(moonlightActionText(.reconnect, host: "PC"), "Reconnect")
        XCTAssertEqual(moonlightActionText(.startSession, host: "PC"), "Start a session")
        XCTAssertEqual(moonlightActionText(.retry, host: "PC"), "Retry")
    }

    func testTheStatusLineSaysWhyTheSessionIsNotUpWhenTheChipDoesNot() {
        XCTAssertNil(moonlightStatusLine(summary(.connected), phase: .streaming))
        XCTAssertNil(moonlightStatusLine(summary(.connecting), phase: .rtsp(.play)))
        XCTAssertNil(moonlightStatusLine(summary(.ready), phase: nil))
        XCTAssertEqual(moonlightStatusLine(summary(.stale), phase: nil), "Not paired yet")
        XCTAssertEqual(moonlightStatusLine(summary(.stale), phase: .failed(.notPaired)), "Not paired yet")
        XCTAssertEqual(moonlightStatusLine(summary(.stale), phase: .failed(.trustLost)), "PC no longer recognises this device")
        XCTAssertEqual(moonlightStatusLine(summary(.stale), phase: .failed(.hostReplaced)), "PC was reset")
        XCTAssertEqual(moonlightStatusLine(summary(.saved), phase: .failed(.unreachable)), "PC is not answering")
        XCTAssertEqual(moonlightStatusLine(summary(.unstable), phase: .failed(.dropped)), "Session on PC ended")
        XCTAssertEqual(moonlightStatusLine(summary(.ready), phase: .failed(.hostEnded)), "PC ended the session")
        XCTAssertEqual(moonlightStatusLine(summary(.ready), phase: .failed(.appAlreadyRunning)), "Another device is using PC")
        XCTAssertEqual(moonlightStatusLine(summary(.ready), phase: .failed(.resumeFailed)), "Could not rejoin the session on PC")
        XCTAssertEqual(moonlightStatusLine(summary(.ready), phase: .failed(.launchRejected)), "PC refused the session")
        XCTAssertEqual(moonlightStatusLine(summary(.ready), phase: .failed(.rtspRejected)), "Could not finish the session on PC")
        XCTAssertEqual(moonlightStatusLine(summary(.ready), phase: .failed(.controlLost)), "Could not finish the session on PC")
        XCTAssertEqual(moonlightStatusLine(summary(.ready), phase: .failed(.noApps)), "No apps on this host")
        XCTAssertNil(moonlightStatusLine(summary(.ready), phase: .failed(.appRemoved)), "the banner names the app")
    }

    func testTheEmulatePickerOfAMoonlightPadOffersTheProtocolsTypesAndSaysWhatAutoSends() {
        XCTAssertEqual(moonlightEmulateOptions().map(\.label), ["Auto", "Xbox", "PlayStation", "Nintendo"])
        XCTAssertEqual(moonlightEmulateOptions().map(\.id), [nil, 1, 2, 3], "the host protocol's numbering")
        XCTAssertEqual(moonlightTypeName(MoonlightControllerType.xbox), "Xbox")
        XCTAssertEqual(moonlightTypeName(MoonlightControllerType.unknown), "Xbox", "anything else a host plugs in as an Xbox pad")
        var slot = ControllerSlot(id: "ds", name: "DualSense", capabilities: ControllerCapabilities(hasMotion: true))
        slot.boundStatus = summary(.connected)
        slot.emulation = SlotEmulation(type: Int(MoonlightControllerType.auto), isOverride: false, offered: [])
        XCTAssertEqual(
            moonlightEmulateDetail(slot),
            "Auto sends PlayStation for this controller.",
            "a pad with motion is a PlayStation pad"
        )
        slot.capabilities = ControllerCapabilities()
        XCTAssertEqual(moonlightEmulateDetail(slot), "Auto sends Xbox for this controller.")
        slot.emulation = SlotEmulation(type: Int(MoonlightControllerType.nintendo), isOverride: true, offered: [])
        XCTAssertEqual(moonlightEmulateDetail(slot), "Dish asks PC to plug in this controller. Some hosts override the choice.")
        let picker = emulatePicker(for: slot, SlotEmulation(type: 3, isOverride: true, offered: []))
        XCTAssertEqual(picker.options.count, 4)
        XCTAssertEqual(emulateSelection(SlotEmulation(type: 3, isOverride: true, offered: [])), 3)
        var unbound = slot
        unbound.boundStatus = nil
        XCTAssertEqual(moonlightEmulateDetail(unbound), "Waiting on the type…")
        var onSatellite = slot
        onSatellite.boundStatus = satellite()
        XCTAssertEqual(
            emulatePicker(for: onSatellite, SlotEmulation(type: 0, isOverride: false, offered: [])).detail,
            "Waiting on the type…",
            "a satellite's picker waits on its catalog"
        )
    }

    func testThePairingEventsAreWordedAndTheHostsOwnWordsAreQuoted() {
        XCTAssertNil(moonlightNotice(for: .pairingPinReady(host: host, pin: "0451")), "the PIN is a sheet")
        let paired = moonlightNotice(for: .paired(host))
        XCTAssertEqual(paired?.severity, .success)
        XCTAssertEqual(paired?.title, "Paired with PC")
        XCTAssertEqual(paired?.body, "Dish starts a session on this host as soon as a controller is bound to it.")
        XCTAssertEqual(paired?.key, "moonlight.pair")
        let refusedPin = moonlightNotice(for: .pairingFailed(
            host: host,
            reason: MoonlightPairingFailure(
                phase: 1,
                kind: .noCertificate,
                httpStatus: 200,
                hostSaid: "A pairing session with this uniqueid already exists"
            )
        ))
        XCTAssertEqual(refusedPin?.title, "PC did not accept the PIN")
        XCTAssertEqual(refusedPin?.body, "A pairing session with this uniqueid already exists", "the host's own words")
        let wrongPin = moonlightNotice(for: .pairingFailed(
            host: host,
            reason: MoonlightPairingFailure(phase: 3, kind: .hostNotAuthentic, httpStatus: 200, hostSaid: "")
        ))
        XCTAssertEqual(wrongPin?.body, "Check that the code went into the right host, then try again.")
        let noIdentity = moonlightNotice(for: .pairingFailed(
            host: host,
            reason: MoonlightPairingFailure(phase: 1, kind: .noIdentity, httpStatus: 0, hostSaid: "")
        ))
        XCTAssertEqual(noIdentity?.body, "Dish has no pairing identity yet. Try again in a moment.")
    }

    func testEverySessionEventIsWordedAndOneBannerPerHostIsKept() {
        let busy = moonlightNotice(for: .appAlreadyRunning(host: host, resumable: false))
        XCTAssertEqual(busy?.title, "Another device is using PC")
        XCTAssertEqual(busy?.quitHost, host, "the way out is to close that app")
        XCTAssertEqual(busy?.key, "moonlight.moonlight:10.0.0.5", "one banner per host")
        XCTAssertEqual(moonlightNotice(for: .rejoinRefused(host))?.quitHost, host)
        XCTAssertEqual(
            moonlightNotice(for: .launchRefused(host: host, message: "Unauthorized"))?.title,
            "PC refused the session: Unauthorized"
        )
        XCTAssertEqual(moonlightNotice(for: .launchRefused(host: host, message: ""))?.title, "PC refused the session")
        XCTAssertEqual(
            moonlightNotice(for: .launchRefused(host: host, message: ""))?.body,
            "Add the controller anyway and Dish will try again the next time you use it."
        )
        XCTAssertEqual(moonlightNotice(for: .setupFailed(host))?.title, "Could not finish the session on PC")
        XCTAssertEqual(
            moonlightNotice(for: .hostFull(host))?.body,
            "A session carries four controllers at most, and PC already has four. Unbind one to make room."
        )
        XCTAssertEqual(moonlightNotice(for: .endedByHost(host))?.severity, .info)
        XCTAssertEqual(moonlightNotice(for: .hostReplaced(host))?.title, "PC was reset")
        XCTAssertEqual(moonlightNotice(for: .appCloseRequested(host))?.title, "Asked PC to close the app it is running.")
        XCTAssertEqual(moonlightNotice(for: .noHostAnswered(address: "10.0.0.9"))?.title, "No Moonlight host answered at 10.0.0.9.")
        XCTAssertEqual(moonlightNotice(for: .noAppsAvailable(host))?.title, "No apps available on PC.")
        XCTAssertEqual(
            moonlightNotice(for: .appRemoved(host: host, appName: "Steam"))?.title,
            "Steam is no longer on PC. Pick another app."
        )
    }

    @MainActor
    func testTheNotifierPostsEachEventOnceAndOffersToCloseTheHostsApp() {
        let center = DishNotificationCenter()
        let events = PassthroughSubject<MoonlightConnectionEvent, Never>()
        let notifier = MoonlightNotifier()
        var quit: [MoonlightHost] = []
        notifier.bind(events: events.eraseToAnyPublisher(), center: center) { quit.append($0) }
        events.send(.pairingPinReady(host: host, pin: "0451"))
        XCTAssertTrue(center.visible.isEmpty)
        events.send(.appAlreadyRunning(host: host, resumable: false))
        XCTAssertEqual(center.visible.map(\.title), ["Another device is using PC"])
        XCTAssertEqual(center.visible.first?.action?.label, "Close the app on PC")
        center.visible.first?.action?.handler()
        XCTAssertEqual(quit, [host])
        events.send(.setupFailed(host))
        XCTAssertEqual(
            center.visible.map(\.title),
            ["Could not finish the session on PC"],
            "a newer word about the same host replaces the last"
        )
        events.send(.paired(host))
        XCTAssertEqual(center.visible.count, 2)
    }
}
