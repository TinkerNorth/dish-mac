// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import Foundation
import SwiftUI

/// What Home reads beyond the slot list: the shell's facts (the global
/// switches, the rates, the binding being applied) and two engine words.
struct HomeInputs {
    let slots: [ControllerSlot]
    let facts: ShellFacts
    var registering = false
    var micPermitted = true
}

/// Home is the signal-path wiring diagram: one boxed row per pad, pad node
/// to wire to host node with the binding printed underneath, or a ghost
/// "Bind…" card for a pad with nowhere to go.
struct HomePageState: Equatable {
    let registering: Bool
    let content: HomeContent
    /// The invitation row under the rows; nil while the empty state invites instead.
    let setUp: SetUpCardState?
    let footer: TelemetryFooterState
}

enum HomeContent: Equatable {
    /// Nothing to draw yet: the empty state, its action the setup walk.
    case empty(title: String, body: String, action: String)
    case rows([HomeRowState])
}

struct HomeRowState: Equatable, Identifiable {
    let id: String
    let pad: PadNodeState
    let wire: WireState
    let destination: HomeDestination
}

struct PadNodeState: Equatable {
    let name: String
    let detail: String
}

struct WireState: Equatable {
    let label: String
    let live: Bool
    let transmitting: Bool
    let help: String
}

enum HomeDestination: Equatable {
    case bound(HostNodeState, HomeStripState)
    case ghost(GhostCardState)
}

/// The host's glyph: a satellite's brand mark in its link's variant, or a
/// Moonlight host's computer.
enum HostGlyph: Equatable {
    case satellite(BrandIconState)
    case moonlight
}

struct HostNodeState: Equatable {
    let name: String
    let detail: String
    let glyph: HostGlyph
    let dot: Color
    let chip: ChipState
}

/// What a strip chip's click asks for: one of the controller's own
/// switches, or its microphone's mute.
enum SlotChipAction: Equatable {
    case setSwitch(SlotSwitch, on: Bool)
    case setMicMuted(Bool)
}

struct HomeStripState: Equatable {
    let title: String
    let chips: [StripChip<SlotChipAction>]
    let editTitle: String
    let editHelp: String
}

struct GhostCardState: Equatable {
    let title: String
    let subtitle: String
}

/// "Set up a controller" opens the setup walk from its first page.
struct SetUpCardState: Equatable {
    let title: String
    let subtitle: String
}

struct TelemetryFooterState: Equatable {
    let rates: String
    let total: String
}

func homePageState(_ inputs: HomeInputs, words: L10n = .app) -> HomePageState {
    let rows = inputs.slots.map { homeRow($0, inputs, words: words) }
    let empty = HomeContent.empty(title: words.nothingSetUpYet, body: words.setupFillsThisDiagramIn, action: words.setUpDishChevron)
    let content = rows.isEmpty ? empty : .rows(rows)
    let setUp = rows.isEmpty ? nil : SetUpCardState(title: words.setUpAController, subtitle: words.plugOneIn)
    return HomePageState(
        registering: inputs.registering,
        content: content,
        setUp: setUp,
        footer: telemetryFooter(inputs.facts.telemetry, words: words)
    )
}

func telemetryFooter(_ telemetry: InputTelemetry, words: L10n = .app) -> TelemetryFooterState {
    TelemetryFooterState(
        rates: words.eventsAndSends(telemetry.eventsPerSecond, telemetry.sendsPerSecond),
        total: words.totalSent(Int(clamping: telemetry.totalSent))
    )
}

private func homeRow(_ slot: ControllerSlot, _ inputs: HomeInputs, words: L10n) -> HomeRowState {
    HomeRowState(
        id: slot.id,
        pad: PadNodeState(name: slot.name, detail: padNodeDetail(slot, words: words)),
        wire: wireState(slot, inputs.facts, words: words),
        destination: rowDestination(slot, inputs, words: words)
    )
}

private func rowDestination(_ slot: ControllerSlot, _ inputs: HomeInputs, words: L10n) -> HomeDestination {
    guard let summary = slot.boundStatus else {
        return .ghost(GhostCardState(title: words.bindEllipsis, subtitle: words.chooseASatelliteForThisPad))
    }
    let strip = HomeStripState(
        title: words.binding,
        chips: stripChips(slot, global: inputs.facts.forwarding, micPermitted: inputs.micPermitted, words: words),
        editTitle: words.editChevron,
        editHelp: words.configureBinding
    )
    return .bound(hostNode(summary, slotId: slot.id, words: words), strip)
}

/// The pad's family (GameController keeps the transport to itself), its
/// battery, and "Unbound" while it has nowhere to go.
func padNodeDetail(_ slot: ControllerSlot, words: L10n = .app) -> String {
    let battery = slot.battery.map { batteryChipText($0, words: words) }
    let unbound = slot.boundConnectionId == nil ? words.unboundTitle : nil
    return ([padFamilyName(slot.family)] + [battery, unbound].compactMap { $0 }).joined(separator: " · ")
}

/// The wire's caption: the pad's measured rate and the link's latency on a
/// live link, whichever are measured, else the link's word.
func wireState(_ slot: ControllerSlot, _ facts: ShellFacts, words: L10n = .app) -> WireState {
    let live = slot.boundStatus.map { showsLatency($0.live) } ?? false
    let applying = facts.binding.draft?.slotId == slot.id && applyInFlight(facts.binding.progress)
    let transmitting = !live && (slot.boundStatus?.live == .connecting || applying)
    let label = live ? liveWireLabel(slot, facts.telemetry, words: words) : words.idle
    return WireState(label: label, live: live, transmitting: transmitting, help: words.wireHelp)
}

private func liveWireLabel(_ slot: ControllerSlot, _ telemetry: InputTelemetry, words: L10n) -> String {
    let hz = telemetry.pads[slot.id]?.reportHz ?? 0
    let rate = hz > 0 ? rateText(hz) : nil
    let latency = slot.boundStatus.flatMap { latencyText($0, words: words) }
    let parts = [rate, latency].compactMap { $0 }
    return parts.isEmpty ? words.live : parts.joined(separator: " · ")
}

/// A rate and the SI unit, which no language translates.
func rateText(_ hz: Int) -> String {
    "\(hz) Hz"
}

/// The host's name, where it lives and which of its slots this pad holds,
/// its glyph, dot and link chip.
func hostNode(_ summary: ConnectionSummary, slotId: String, words: L10n = .app) -> HostNodeState {
    let ordinal = (summary.boundSlotIds.firstIndex(of: slotId) ?? 0) + 1
    let slotLine = words.slotOf(ordinal, hostSlotCapacity(summary.kind))
    let detail = summary.address.isEmpty ? slotLine : "\(summary.address) · \(slotLine)"
    return HostNodeState(
        name: connectionTitle(summary),
        detail: detail,
        glyph: hostGlyph(summary),
        dot: linkDotColor(summary.live),
        chip: ChipState(text: linkStateText(summary.live, words: words), color: linkDotColor(summary.live))
    )
}

/// A satellite and a Moonlight session each carry four pads; a Bluetooth link one.
func hostSlotCapacity(_ kind: ConnectionKind) -> Int {
    switch kind {
    case .satellite: SatelliteSlots.maxPerSatellite
    case .moonlight: MoonlightProtocol.maxPads
    case .bluetooth: 1
    }
}

func hostGlyph(_ summary: ConnectionSummary) -> HostGlyph {
    switch summary.kind {
    case .satellite, .bluetooth: .satellite(brandIconState(for: summary.live))
    case .moonlight: .moonlight
    }
}

/// The strip: the type the binding emulates, then the controller's chips
/// with its own switches clickable, then its microphone's word and lamp.
func stripChips(
    _ slot: ControllerSlot,
    global: ForwardingFlags,
    micPermitted: Bool,
    words: L10n = .app
) -> [StripChip<SlotChipAction>] {
    let type = StripChip<SlotChipAction>(
        id: "type",
        text: words.emulatedAs(emulatedTypeName(slot.emulation, words: words)),
        look: CapabilityChipLook(ink: DishTheme.primary, on: true, absent: false),
        help: words.emulateAs,
        action: nil
    )
    let switches = capabilityChips(for: slot, global, micPermitted: micPermitted, words: words).map(switchStripChip)
    let mic = micStatusChip(slot, words: words).map { stripChip($0, action: .setMicMuted(!slot.micMuted)) }
    let lamp = micLampChip(slot, words: words).map { stripChip($0, action: nil) }
    return [type] + switches + [mic, lamp].compactMap { $0 }
}

private func switchStripChip(_ chip: CapabilityChipModel) -> StripChip<SlotChipAction> {
    let action = chip.toggle ? chip.switch.map { SlotChipAction.setSwitch($0, on: !chip.on) } : nil
    return stripChip(chip, action: action)
}

private func stripChip(_ chip: CapabilityChipModel, action: SlotChipAction?) -> StripChip<SlotChipAction> {
    StripChip(id: chip.label, text: chip.label, look: capabilityChipLook(chip), help: chip.help, action: action)
}

/// The battery as a chip's word: full, rising while it charges, else its level.
func batteryChipText(_ reading: BatteryReading, words: L10n = .app) -> String {
    switch (reading.state, reading.level) {
    case (.full, _): words.batteryFull
    case let (.charging, level?): words.batteryPercentRising(level)
    case let (.discharging, level?), let (.unknown, level?): words.batteryPercent(level)
    case (.charging, nil): words.batteryCharging
    case (.discharging, nil), (.unknown, nil): words.batteryLevelUnknown
    }
}

/// A bound row is a card on the surface; the ghost "Bind…" row is only its outline.
func signalRowFill(_ destination: HomeDestination) -> Color {
    switch destination {
    case .bound: DishTheme.surface
    case .ghost: Color.clear
    }
}
