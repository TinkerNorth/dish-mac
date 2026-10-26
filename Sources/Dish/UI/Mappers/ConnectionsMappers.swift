// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import Foundation
import SwiftUI

// MARK: - A connection's words

/// A connection's display name: its advertised name, or its address when it
/// has none.
func connectionTitle(_ summary: ConnectionSummary) -> String {
    summary.name.isEmpty ? summary.address : summary.name
}

/// The address line, numeric and untranslated: a satellite's IP and UDP
/// port, a Moonlight host's address and the protocol's name.
func connectionAddressLine(_ summary: ConnectionSummary) -> String {
    switch summary.kind {
    case .satellite, .bluetooth: summary.udpPort.map { "\(summary.address) • UDP \($0)" } ?? summary.address
    case .moonlight: "\(summary.address) • Moonlight"
    }
}

/// The one-way latency while a session is up and has an ack to show for it.
func latencyText(_ summary: ConnectionSummary, words: L10n = .app) -> String? {
    guard showsLatency(summary.live), let latencyMs = summary.latencyMs else { return nil }
    return String(format: "%.1f ms", locale: words.catalog.locale, latencyMs)
}

// MARK: - Chips

/// A chip's word, its colour token, and the line its hover shows.
struct ChipState: Equatable {
    let text: String
    let color: Color
    var help = ""
}

func tierChip(_ kind: ConnectionKind, words: L10n = .app) -> ChipState {
    ChipState(text: linkTierText(kind, words: words), color: linkTierColor(kind), help: linkTierHelp(kind, words: words))
}

func linkChip(_ state: LinkState, words: L10n = .app) -> ChipState {
    ChipState(text: linkStateText(state, words: words), color: linkChipColor(state))
}

/// The desktops' tones: live in the success colour, every state that waits
/// on something in the warning colour, a reachable paired host in the accent.
func linkChipColor(_ state: LinkState) -> Color {
    switch state {
    case .connected: DishTheme.success
    case .connecting, .unstable, .stale: DishTheme.warning
    case .ready: DishTheme.primary
    case .found, .saved: DishTheme.muted
    }
}

/// Nothing for a satellite that is current or not negotiated with yet.
func compatChip(_ compat: ProtocolCompat, words: L10n = .app) -> ChipState? {
    protocolCompatText(compat, words: words).map { ChipState(text: $0, color: protocolCompatColor(compat)) }
}

// MARK: - The Connections page

/// What the page is drawn from: the rows, the pads that ride them, the
/// scans' facts and the pairing card open on a row.
struct ConnectionsInputs {
    let connections: [ConnectionSummary]
    let slots: [ControllerSlot]
    let facts: ConnectionsFacts
    let openPairing: OpenPairing?
}

struct ConnectionsPageState: Equatable {
    let foundTitle: String
    let scan: ScanControlState
    let found: FoundSectionState
    let moonlightDoor: DoorRowState
    let pairedTitle: String
    let paired: PairedSectionState
    let address: AddressFieldState
    let forget: ForgetDialogState
}

/// The section header's Scan button and the bar under it while a scan runs.
struct ScanControlState: Equatable {
    let title: String
    let enabled: Bool
    let showsBar: Bool
}

func scanControl(scanning: Bool, words: L10n = .app) -> ScanControlState {
    ScanControlState(title: scanning ? words.scanning : words.scan, enabled: !scanning, showsBar: scanning)
}

/// An empty list's card, with the refusal under it when macOS is the reason.
struct EmptyStateModel: Equatable {
    let title: String
    let message: String
    var hint: String?
}

/// An empty list after a scan: the card and its two ways forward, and the
/// way to System Settings when macOS refused the network.
struct NothingFoundState: Equatable {
    let card: EmptyStateModel
    let getApp: String
    let getAppURL: URL?
    let secondary: String
    var settings: SettingsLinkState?
}

/// A button that opens a pane of System Settings.
struct SettingsLinkState: Equatable {
    let title: String
    let url: URL?
}

/// Android's explain-then-ask card: why macOS is about to ask, and the
/// button that runs the scan that makes it.
struct PrimingCardState: Equatable {
    let title: String
    let message: String
    let action: String
}

enum FoundSectionState: Equatable {
    /// Before the first scan ever: the prompt explained first.
    case priming(PrimingCardState)
    case looking(EmptyStateModel)
    case nothing(NothingFoundState)
    case rows([FoundRowState])
}

struct FoundRowState: Equatable, Identifiable {
    let id: String
    let title: String
    let detail: String
    let chips: [ChipState]
    let pairTitle: String
    let pairEnabled: Bool
    let pairing: OpenPairing?
}

/// A row that opens another page.
struct DoorRowState: Equatable {
    let title: String
    let subtitle: String
}

enum PairedSectionState: Equatable {
    case empty(EmptyStateModel)
    case cards([PairedCardState])
}

struct PairedCardState: Equatable, Identifiable {
    let id: String
    let glyph: BrandIconState
    let dot: Color
    let title: String
    let address: String
    let latency: String?
    let chips: [ChipState]
    let carrying: CarryingState
    let actions: [SatelliteActionState]
    let menu: RowMenuState
    let pairing: OpenPairing?
}

/// The read-only manifest of the pads a host carries: a line per pad, or
/// the line that says none is bound.
struct CarryingState: Equatable {
    let title: String
    let lines: [String]
    let emptyLine: String?
}

struct SatelliteActionState: Equatable, Identifiable {
    let kind: SatelliteRowAction
    let title: String
    let enabled: Bool
    let working: Bool

    var id: String {
        title
    }
}

/// The row's ⋯ menu: its accessible name and the one destructive item.
struct RowMenuState: Equatable {
    let label: String
    let forget: String
}

/// A typed-address field: what it asks for, whether Add can run, and why
/// the last entry did not read.
struct AddressFieldState: Equatable {
    let placeholder: String
    let addTitle: String
    let canAdd: Bool
    let error: String?
}

func connectionsPageState(_ inputs: ConnectionsInputs, draft: String, words: L10n = .app) -> ConnectionsPageState {
    let satellites = inputs.connections.filter { $0.kind == .satellite }
    let rejected = inputs.facts.rejectedAddress == .satellite
    let addressError = rejected ? words.invalidAddress : nil
    return ConnectionsPageState(
        foundTitle: words.found,
        scan: scanControl(scanning: inputs.facts.scanning, words: words),
        found: foundSection(inputs, known: satellites, words: words),
        moonlightDoor: DoorRowState(title: words.moonlightHosts, subtitle: words.streamToASunshinePc),
        pairedTitle: words.pairedTitle,
        paired: pairedSection(satellites, inputs, words: words),
        address: addressField(draft: draft, placeholder: words.addByAddressPlaceholder, error: addressError, words: words),
        forget: forgetDialog(
            inputs.facts.pendingForget,
            connections: inputs.connections,
            slots: inputs.slots,
            remembered: inputs.facts.rememberedPads,
            words: words
        )
    )
}

func addressField(draft: String, placeholder: String, error: String?, words: L10n = .app) -> AddressFieldState {
    let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    return AddressFieldState(placeholder: placeholder, addTitle: words.add, canAdd: !typed.isEmpty, error: error)
}

// MARK: - FOUND

/// The copy never claims to be searching once the sweep has finished.
func foundSection(_ inputs: ConnectionsInputs, known: [ConnectionSummary], words: L10n = .app) -> FoundSectionState {
    let found = foundServers(inputs.facts.discovered, known: known)
    guard found.isEmpty else { return .rows(found.map { foundRow($0, inputs, words: words) }) }
    if let priming = primingCard(inputs.facts, words: words) { return .priming(priming) }
    guard !inputs.facts.scanning else {
        return .looking(EmptyStateModel(title: words.lookingForSatellites, message: words.scanningOverMdnsAndBroadcast))
    }
    let hint = inputs.facts.localNetworkDenied ? words.localNetworkDenied : nil
    let card = EmptyStateModel(title: words.noSatellitesFound, message: words.satelliteShowsUpHere, hint: hint)
    let getApp = URL(string: DishLinks.satellite)
    var nothing = NothingFoundState(card: card, getApp: words.getSatellite, getAppURL: getApp, secondary: words.scanAgain)
    nothing.settings = localNetworkSettings(denied: inputs.facts.localNetworkDenied, words: words)
    return .nothing(nothing)
}

/// Nil once the scan that raises the prompt has been explained and run.
func primingCard(_ facts: ConnectionsFacts, words: L10n = .app) -> PrimingCardState? {
    guard !facts.localNetworkPrimed else { return nil }
    return PrimingCardState(title: words.macosWillAskForTheNetwork, message: words.allowLocalNetworkToScan, action: words.showMeThePrompt)
}

/// Privacy & Security › Local Network, offered only once macOS has refused.
func localNetworkSettings(denied: Bool, words: L10n = .app) -> SettingsLinkState? {
    guard denied else { return nil }
    return SettingsLinkState(title: words.openSystemSettings, url: URL(string: DishLinks.localNetworkSettings))
}

func foundRow(_ server: DiscoveredServer, _ inputs: ConnectionsInputs, words: L10n = .app) -> FoundRowState {
    let pairing = inputs.facts.pairingInFlight.contains(server.id)
    return FoundRowState(
        id: server.id,
        title: serverTitle(server),
        detail: foundServerDetail(server, words: words),
        chips: [tierChip(.satellite, words: words), linkChip(.found, words: words)],
        pairTitle: pairing ? words.pairing : words.pairEllipsis,
        pairEnabled: !pairing,
        pairing: openCard(on: server.id, inputs.openPairing)
    )
}

private func openCard(on id: String, _ open: OpenPairing?) -> OpenPairing? {
    open?.server.id == id ? open : nil
}

// MARK: - PAIRED

func pairedSection(_ satellites: [ConnectionSummary], _ inputs: ConnectionsInputs, words: L10n = .app) -> PairedSectionState {
    guard !satellites.isEmpty else {
        return .empty(EmptyStateModel(title: words.nothingPairedYet, message: words.pairASatelliteAndDishSavesIt))
    }
    return .cards(satellites.map { pairedCard($0, inputs, words: words) })
}

func pairedCard(_ summary: ConnectionSummary, _ inputs: ConnectionsInputs, words: L10n = .app) -> PairedCardState {
    let title = connectionTitle(summary)
    let chips = [tierChip(summary.kind, words: words)] + [compatChip(summary.compat, words: words)].compactMap { $0 }
    return PairedCardState(
        id: summary.id,
        glyph: brandIconState(for: summary.live),
        dot: linkDotColor(summary.live),
        title: title,
        address: connectionAddressLine(summary),
        latency: latencyText(summary, words: words),
        chips: chips + [linkChip(summary.live, words: words)],
        carrying: carrying(summary, slots: inputs.slots, words: words),
        actions: satelliteActions(summary, pairing: inputs.facts.pairingInFlight.contains(summary.id), words: words),
        menu: RowMenuState(label: words.moreActionsFor(title), forget: words.forget),
        pairing: openCard(on: summary.id, inputs.openPairing)
    )
}

/// One primary action by the link's state: a live link disconnects, a
/// revoked key pairs again (Connect would only fail), anything else
/// connects; pairing in flight and a session opening read as one working
/// state.
func satelliteActions(_ summary: ConnectionSummary, pairing: Bool, words: L10n = .app) -> [SatelliteActionState] {
    switch summary.live {
    case .connected, .unstable:
        [SatelliteActionState(kind: .disconnect, title: words.disconnect, enabled: true, working: false)]
    case .connecting:
        [SatelliteActionState(kind: .connect, title: words.connecting, enabled: false, working: true)]
    case .stale:
        [SatelliteActionState(kind: .pair, title: pairing ? words.pairing : words.pairEllipsis, enabled: !pairing, working: pairing)]
    case .found, .saved, .ready:
        [SatelliteActionState(kind: .connect, title: pairing ? words.pairing : words.connect, enabled: !pairing, working: pairing)]
    }
}

/// "<pad> — as <type>" per pad the host carries; the type belongs to the
/// binding, so it prints here and never on the pad.
func carrying(_ summary: ConnectionSummary, slots: [ControllerSlot], words: L10n = .app) -> CarryingState {
    let lines = summary.boundSlotIds.map { id in carriedLine(id, slots: slots, words: words) }
    return CarryingState(title: words.carrying, lines: lines, emptyLine: lines.isEmpty ? words.nothingBoundYet : nil)
}

private func carriedLine(_ slotId: String, slots: [ControllerSlot], words: L10n) -> String {
    let slot = slots.first { $0.id == slotId }
    let name = slot?.name ?? slotId
    guard let type = slot?.emulation?.current?.label else { return name }
    return words.padAsType(name, type)
}

// MARK: - Forget asks first

/// The confirmation a Forget raises; hidden while nothing waits on it.
struct ForgetDialogState: Equatable {
    let shown: Bool
    let title: String
    let message: String
    let confirm: String
    let cancel: String
}

/// It names every pad it drops, one per line, the ones bound now and the
/// ones remembered for a pad that is away: "some bindings will be lost" is
/// not a confirmation. A Moonlight host keeps its own record of this device,
/// and the words say so.
func forgetDialog(
    _ pendingId: String?,
    connections: [ConnectionSummary],
    slots: [ControllerSlot],
    remembered: [String: [String]] = [:],
    words: L10n = .app
) -> ForgetDialogState {
    let summary = connections.first { $0.id == pendingId }
    guard let summary else {
        return ForgetDialogState(shown: false, title: "", message: "", confirm: words.forget, cancel: words.cancel)
    }
    let name = connectionTitle(summary)
    let lead = summary.kind == .moonlight ? words.forgetMoonlightHelp(name) : words.pairingKeyIsDeleted
    let bound = summary.boundSlotIds.map { id in slots.first { $0.id == id }?.name ?? id }
    let pads = bound + (remembered[summary.id] ?? [])
    let dropped = pads.isEmpty ? [] : [words.bindingsRideOnIt(pads.count)] + pads.map { "· \($0)" }
    return ForgetDialogState(
        shown: true,
        title: words.forgetQuestion(name),
        message: ([lead] + dropped).joined(separator: "\n"),
        confirm: words.forget,
        cancel: words.cancel
    )
}
