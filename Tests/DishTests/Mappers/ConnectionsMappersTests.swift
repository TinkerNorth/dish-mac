// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import XCTest
@testable import Dish

/// The Connections page as data: a connection's words, the chips, the FOUND
/// empty states and rows, the PAIRED cards with their manifest and their
/// one action by state, the address field, and the Forget confirmation.
final class ConnectionsMappersTests: XCTestCase {

    private let desk = DiscoveredServer(name: "Desk", ip: "10.0.0.5", machineId: "desk", source: .mdns)

    private func satellite(
        _ live: LinkState,
        name: String = "Den",
        bound: [String] = [],
        latencyMs: Double? = nil,
        compat: ProtocolCompat = .unknown
    ) -> ConnectionSummary {
        ConnectionSummary(
            id: "mid:den",
            name: name,
            address: "10.0.0.2",
            udpPort: 9876,
            live: live,
            boundSlotId: bound.first,
            latencyMs: latencyMs,
            compat: compat,
            boundSlotIds: bound
        )
    }

    private func host(bound: [String] = []) -> ConnectionSummary {
        ConnectionSummary(
            id: "moonlight:10.0.0.9",
            name: "PC",
            address: "10.0.0.9",
            live: .ready,
            boundSlotId: bound.first,
            kind: .moonlight,
            boundSlotIds: bound
        )
    }

    private func pad(_ id: String, _ name: String, as type: String? = nil) -> ControllerSlot {
        let offered = type.map { [PickableType(id: 1, slug: "", name: $0, shortName: "", description: "")] } ?? []
        let emulation = type.map { _ in SlotEmulation(type: 1, isOverride: false, offered: offered) }
        return ControllerSlot(id: id, name: name, emulation: emulation)
    }

    private func inputs(
        _ connections: [ConnectionSummary] = [],
        slots: [ControllerSlot] = [],
        facts: ConnectionsFacts = ConnectionsFacts(),
        open: OpenPairing? = nil
    ) -> ConnectionsInputs {
        ConnectionsInputs(connections: connections, slots: slots, facts: facts, openPairing: open)
    }

    private func facts(
        discovered: [DiscoveredServer] = [],
        scanning: Bool = false,
        denied: Bool = false,
        pairing: Set<String> = []
    ) -> ConnectionsFacts {
        var facts = ConnectionsFacts()
        facts.discovered = discovered
        facts.scanning = scanning
        facts.localNetworkDenied = denied
        facts.pairingInFlight = pairing
        return facts
    }

    private struct NotOneCard: Error {}

    private func onlyCard(_ state: PairedSectionState) throws -> PairedCardState {
        guard case let .cards(cards) = state, cards.count == 1 else { throw NotOneCard() }
        return cards[0]
    }

    // MARK: - A connection's words

    func testATitleIsTheNameElseTheAddress() {
        XCTAssertEqual(connectionTitle(satellite(.saved)), "Den")
        XCTAssertEqual(connectionTitle(satellite(.saved, name: "")), "10.0.0.2")
    }

    func testTheAddressLineIsIpAndUdpPortForASatelliteAndTheProtocolForAHost() {
        XCTAssertEqual(connectionAddressLine(satellite(.saved)), "10.0.0.2 • UDP 9876")
        XCTAssertEqual(connectionAddressLine(host()), "10.0.0.9 • Moonlight")
        let portless = ConnectionSummary(id: "x", name: "", address: "10.0.0.3", live: .saved, boundSlotId: nil)
        XCTAssertEqual(connectionAddressLine(portless), "10.0.0.3")
    }

    func testLatencyShowsOnlyWhileASessionIsUpWithAnAck() {
        XCTAssertEqual(latencyText(satellite(.connected, latencyMs: 3.25)), "3.2 ms")
        XCTAssertEqual(latencyText(satellite(.unstable, latencyMs: 8)), "8.0 ms")
        XCTAssertNil(latencyText(satellite(.connected)), "no ack yet")
        XCTAssertNil(latencyText(satellite(.saved, latencyMs: 3)), "a resting link has no latency")
    }

    // MARK: - Chips

    func testTheLinkChipSpeaksTheDesktopsWordsAndTones() {
        let chips = [LinkState.found, .stale, .saved, .ready, .connecting, .connected, .unstable].map { linkChip($0) }
        XCTAssertEqual(chips.map(\.text), ["Found", "Needs pairing", "Offline", "Ready", "Connecting…", "Online", "Unsteady"])
        XCTAssertEqual(
            chips.map(\.color),
            [
                DishTheme.muted,
                DishTheme.warning,
                DishTheme.muted,
                DishTheme.primary,
                DishTheme.warning,
                DishTheme.success,
                DishTheme.warning
            ]
        )
    }

    func testTheTierChipCarriesItsHelpAndTheCompatChipOnlyWhenItSaysSomething() {
        XCTAssertEqual(tierChip(.satellite).text, linkTierText(.satellite))
        XCTAssertEqual(tierChip(.moonlight).help, linkTierHelp(.moonlight))
        XCTAssertNil(compatChip(.current))
        XCTAssertNil(compatChip(.unknown))
        XCTAssertEqual(compatChip(.dishUpdateRequired), ChipState(text: "Dish update required", color: DishTheme.error))
    }

    // MARK: - Scan and FOUND

    func testTheScanButtonReportsTheSweepAndTheBarRunsWithIt() {
        XCTAssertEqual(scanControl(scanning: false), ScanControlState(title: "Scan", enabled: true, showsBar: false))
        XCTAssertEqual(scanControl(scanning: true), ScanControlState(title: "Scanning…", enabled: false, showsBar: true))
    }

    func testAnEmptyFoundListLooksWhileTheSweepRuns() {
        let state = foundSection(inputs(facts: facts(scanning: true)), known: [])
        XCTAssertEqual(state, .looking(EmptyStateModel(
            title: "Looking for satellites",
            message: "Scanning your network over mDNS and UDP broadcast. Hosts appear here as they answer."
        )))
    }

    func testAnEmptyFoundListAfterTheSweepOffersSatelliteAndAnotherScan() {
        guard case let .nothing(nothing) = foundSection(inputs(), known: []) else { return XCTFail("nothing found") }
        XCTAssertEqual(nothing.card.title, "No satellites found")
        XCTAssertNil(nothing.card.hint, "an open network needs no hint")
        XCTAssertEqual(nothing.getApp, "Get Satellite ↗")
        XCTAssertEqual(nothing.getAppURL, URL(string: "https://dish.tinkernorth.com/downloads/satellite"))
        XCTAssertEqual(nothing.secondary, "Scan again")
    }

    func testARefusedLocalNetworkIsTheEmptyStatesHint() {
        let state = foundSection(inputs(facts: facts(denied: true)), known: [])
        guard case let .nothing(nothing) = state else { return XCTFail("nothing found") }
        XCTAssertEqual(nothing.card.hint, L10n.app.localNetworkDenied)
    }

    func testAFoundRowNamesTheServerHowItWasHeardAndOffersPair() {
        let state = foundSection(inputs(facts: facts(discovered: [desk])), known: [])
        let row = FoundRowState(
            id: desk.id,
            title: "Desk",
            detail: "10.0.0.5 · mDNS",
            chips: [tierChip(.satellite), linkChip(.found)],
            pairTitle: "Pair…",
            pairEnabled: true,
            pairing: nil
        )
        XCTAssertEqual(state, .rows([row]))
    }

    func testAFoundRowPairingReadsPairingAndOpensItsCard() {
        let open = OpenPairing(server: desk, attempt: PairingAttempt(clientPin: "1234", phase: .awaiting))
        let state = foundSection(inputs(facts: facts(discovered: [desk], pairing: [desk.id]), open: open), known: [])
        guard case let .rows(rows) = state else { return XCTFail("rows") }
        XCTAssertEqual(rows.first?.pairTitle, "Pairing…")
        XCTAssertEqual(rows.first?.pairEnabled, false)
        XCTAssertEqual(rows.first?.pairing, open)
    }

    func testAPairedSatelliteIsNotListedAsFoundAgain() {
        let known = ConnectionSummary(id: desk.id, name: "Desk", address: desk.ip, live: .ready, boundSlotId: nil)
        guard case .nothing = foundSection(inputs([known], facts: facts(discovered: [desk])), known: [known]) else {
            return XCTFail("the one-spot rule keeps a remembered id out of FOUND")
        }
    }

    // MARK: - PAIRED

    func testNothingPairedSaysSo() {
        XCTAssertEqual(
            pairedSection([], inputs()),
            .empty(EmptyStateModel(title: "Nothing paired yet", message: "Pair a satellite and Dish saves it here for next time."))
        )
    }

    func testAPairedCardNamesItsHostAddressLatencyAndChips() throws {
        let summary = satellite(.connected, latencyMs: 2.5, compat: .satelliteUpdateAvailable)
        let card = try onlyCard(pairedSection([summary], inputs([summary])))
        XCTAssertEqual(card.title, "Den")
        XCTAssertEqual(card.address, "10.0.0.2 • UDP 9876")
        XCTAssertEqual(card.latency, "2.5 ms")
        XCTAssertEqual(card.glyph, .connected)
        XCTAssertEqual(card.dot, DishTheme.success)
        XCTAssertEqual(card.chips.map(\.text), [linkTierText(.satellite), "Satellite update recommended", "Online"])
        XCTAssertEqual(card.menu, RowMenuState(label: "More actions for Den", forget: "Forget"))
    }

    func testTheManifestNamesEachPadWithTheTypeItIsSentAs() {
        let summary = satellite(.connected, bound: ["a", "b"])
        let slots = [pad("a", "DualSense", as: "DS4"), pad("b", "Joy-Con")]
        let manifest = carrying(summary, slots: slots)
        XCTAssertEqual(manifest.title, "Carrying")
        XCTAssertEqual(manifest.lines, ["DualSense — as DS4", "Joy-Con"])
        XCTAssertNil(manifest.emptyLine)
        XCTAssertEqual(carrying(satellite(.saved, bound: ["gone"]), slots: []).lines, ["gone"], "a pad that left is named by its id")
    }

    func testAnEmptyManifestSaysNothingIsBound() {
        let manifest = carrying(satellite(.saved), slots: [])
        XCTAssertEqual(manifest.lines, [])
        XCTAssertEqual(manifest.emptyLine, "Nothing bound yet")
    }

    func testTheCardsActionFollowsTheLink() {
        let action = { (live: LinkState, pairing: Bool) in satelliteActions(self.satellite(live), pairing: pairing) }
        let disconnect = SatelliteActionState(kind: .disconnect, title: "Disconnect", enabled: true, working: false)
        XCTAssertEqual(action(.connected, false), [disconnect])
        XCTAssertEqual(action(.unstable, false), [disconnect])
        XCTAssertEqual(
            action(.connecting, false),
            [SatelliteActionState(kind: .connect, title: "Connecting…", enabled: false, working: true)]
        )
        XCTAssertEqual(action(.stale, false), [SatelliteActionState(kind: .pair, title: "Pair…", enabled: true, working: false)])
        XCTAssertEqual(action(.stale, true), [SatelliteActionState(kind: .pair, title: "Pairing…", enabled: false, working: true)])
        let connect = SatelliteActionState(kind: .connect, title: "Connect", enabled: true, working: false)
        XCTAssertEqual(action(.saved, false), [connect])
        XCTAssertEqual(action(.ready, false), [connect])
        XCTAssertEqual(action(.found, false), [connect])
        XCTAssertEqual(action(.ready, true), [SatelliteActionState(kind: .connect, title: "Pairing…", enabled: false, working: true)])
    }

    func testAPairedCardWhosePairingIsOpenCarriesTheCard() throws {
        let summary = satellite(.stale)
        let server = DiscoveredServer(name: "Den", ip: "10.0.0.2", machineId: "den")
        let open = OpenPairing(server: server, attempt: PairingAttempt(clientPin: "1234", phase: .awaiting))
        XCTAssertEqual(try onlyCard(pairedSection([summary], inputs([summary], open: open))).pairing, open)
        XCTAssertNil(try onlyCard(pairedSection([summary], inputs([summary]))).pairing)
    }

    // MARK: - The page

    func testThePagePairsOnlySatellitesAndLeadsToTheMoonlightHosts() throws {
        let state = connectionsPageState(inputs([satellite(.ready), host()]), draft: "")
        XCTAssertEqual(state.foundTitle, "Found")
        XCTAssertEqual(state.pairedTitle, "Paired")
        XCTAssertEqual(try onlyCard(state.paired).id, "mid:den", "a Moonlight host lives on its own page")
        XCTAssertEqual(state.moonlightDoor.title, "Moonlight hosts")
        XCTAssertEqual(state.moonlightDoor.subtitle, "Stream to a PC running Sunshine, Apollo or Wolf instead of a satellite.")
        XCTAssertFalse(state.forget.shown)
    }

    func testTheAddressFieldAddsOnlyTypedTextAndShowsWhyAnEntryDidNotRead() {
        XCTAssertFalse(connectionsPageState(inputs(), draft: "  ").address.canAdd)
        XCTAssertTrue(connectionsPageState(inputs(), draft: "10.0.0.7").address.canAdd)
        XCTAssertNil(connectionsPageState(inputs(), draft: "").address.error)
        var rejected = ConnectionsFacts()
        rejected.rejectedAddress = .satellite
        XCTAssertEqual(
            connectionsPageState(inputs(facts: rejected), draft: "x").address.error,
            "Enter an IPv4 address like 192.168.1.50 (optionally :port)"
        )
        rejected.rejectedAddress = .moonlight
        XCTAssertNil(connectionsPageState(inputs(facts: rejected), draft: "x").address.error, "the other page's field")
    }

    // MARK: - Forget asks first

    func testNothingWaitingHidesTheDialog() {
        XCTAssertFalse(forgetDialog(nil, connections: [satellite(.saved)], slots: []).shown)
        XCTAssertFalse(forgetDialog("gone", connections: [satellite(.saved)], slots: []).shown, "the row left meanwhile")
    }

    func testForgettingASatelliteSaysItsKeyGoes() {
        let dialog = forgetDialog("mid:den", connections: [satellite(.saved)], slots: [])
        XCTAssertTrue(dialog.shown)
        XCTAssertEqual(dialog.title, "Forget Den?")
        XCTAssertEqual(dialog.message, "Its pairing key is deleted — you’ll need the PIN again.")
        XCTAssertEqual(dialog.confirm, "Forget")
        XCTAssertEqual(dialog.cancel, "Cancel")
    }

    func testForgettingNamesEveryBindingItDrops() {
        let dialog = forgetDialog("mid:den", connections: [satellite(.connected, bound: ["a"])], slots: [pad("a", "DualSense")])
        XCTAssertEqual(dialog.message, """
        Its pairing key is deleted — you’ll need the PIN again.
        1 binding rides on it and will be dropped:
        · DualSense
        """)
    }

    func testForgettingAMoonlightHostSaysTheHostKeepsItsOwnRecord() {
        let dialog = forgetDialog(host().id, connections: [host(bound: ["a", "b"])], slots: [pad("a", "Pro"), pad("b", "Joy-Con")])
        XCTAssertEqual(dialog.title, "Forget PC?")
        XCTAssertEqual(dialog.message, """
        Dish deletes its pairing and you will need the PIN again. PC keeps its own record of this device until you remove it there.
        2 bindings ride on it and will be dropped:
        · Pro
        · Joy-Con
        """)
    }
}
