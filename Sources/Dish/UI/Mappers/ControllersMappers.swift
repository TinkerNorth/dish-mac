// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import Foundation
import SwiftUI

/// Controllers is the inventory of pads: everything that belongs to the
/// device, and the one binding-aware hand-off, "Bound · host ›", into
/// Configure binding.
struct ControllersPageState: Equatable {
    let registering: Bool
    let content: ControllersContent
    let footer: TelemetryFooterState
}

enum ControllersContent: Equatable {
    case empty(title: String, body: String)
    case cards([ControllerCardState])
}

struct ControllerCardState: Equatable, Identifiable {
    let id: String
    let name: String
    let dot: Color
    /// The family (GameController keeps the transport to itself) and the
    /// measured report rate.
    let link: String
    let binding: CardBinding
    let chips: [CapabilityChipState]
    let mic: MicToggleState?
    /// The motion rate, once the pad sends motion.
    let motionRate: String?
    let deadZones: String
    /// The pad's input path, once the paths have facts for it.
    let path: PadPathState?
    /// The accent while the pad reports input, so identical pads can be told apart.
    let stroke: Color
}

/// The binding's hand-off: the host it is bound to, or the way to bind it.
enum CardBinding: Equatable {
    case bound(title: String)
    case unbound(label: String, action: String)
}

struct CapabilityChipState: Equatable, Identifiable {
    let id: String
    let text: String
    let look: CapabilityChipLook
    let help: String
}

/// The microphone's live control, present only while the binding arms it.
struct MicToggleState: Equatable {
    let title: String
    /// Live, a click mutes; muted, a click unmutes.
    let muteOnClick: Bool
    let help: String
}

func controllersPageState(
    slots: [ControllerSlot],
    facts: ShellFacts,
    registering: Bool = false,
    words: L10n = .app
) -> ControllersPageState {
    let cards = slots.map { controllerCard($0, facts.telemetry, path: facts.inputPaths[$0.id], words: words) }
    return ControllersPageState(
        registering: registering,
        content: cards.isEmpty ? .empty(title: words.noControllersConnected, body: words.plugOneIn) : .cards(cards),
        footer: telemetryFooter(facts.telemetry, words: words)
    )
}

func controllerCard(
    _ slot: ControllerSlot,
    _ telemetry: InputTelemetry,
    path: SlotInputPath? = nil,
    words: L10n = .app
) -> ControllerCardState {
    let rates = telemetry.pads[slot.id]
    return ControllerCardState(
        id: slot.id,
        name: slot.name,
        dot: slotDotColor(slot),
        link: padLinkLine(slot.family, reportHz: rates?.reportHz ?? 0),
        binding: cardBinding(slot, words: words),
        chips: deviceChips(slot, words: words),
        mic: micToggle(slot, words: words),
        motionRate: motionRateText(rates?.motionHz ?? 0, words: words),
        deadZones: words.deadZonesEllipsis,
        path: padPathState(path, words: words),
        stroke: telemetry.reporting.contains(slot.id) ? DishTheme.primary : DishTheme.cardStroke
    )
}

/// "DualSense · 250 Hz", or the family alone before the pad has sent a report.
func padLinkLine(_ family: PadFamily, reportHz: Int) -> String {
    let name = padFamilyName(family)
    return reportHz > 0 ? "\(name) · \(rateText(reportHz))" : name
}

func cardBinding(_ slot: ControllerSlot, words: L10n = .app) -> CardBinding {
    guard let summary = slot.boundStatus else { return .unbound(label: words.notBoundLower, action: words.bindEllipsis) }
    return .bound(title: words.boundToHost(connectionTitle(summary)))
}

/// Gyro and Touchpad present or absent, Lightbar only when present (its
/// absence is the normal case, not a finding), and the battery once read.
func deviceChips(_ slot: ControllerSlot, words: L10n = .app) -> [CapabilityChipState] {
    let caps = slot.capabilities
    let gyro = presenceChip(id: "gyro", present: caps.hasMotion, yes: words.gyro, no: words.noGyro)
    let touchpad = presenceChip(id: "touchpad", present: caps.hasTouchpad, yes: words.touchpad, no: words.noTouchpad)
    let lightbar = caps.hasLightbar ? presenceChip(id: "lightbar", present: true, yes: words.lightbar, no: words.lightbar) : nil
    let battery = slot.battery.map { batteryChip($0, words: words) }
    return [gyro, touchpad] + [lightbar, battery].compactMap { $0 }
}

private func presenceChip(id: String, present: Bool, yes: String, no: String) -> CapabilityChipState {
    let look = CapabilityChipLook(ink: present ? DishTheme.primary : DishTheme.muted, on: present, absent: !present)
    return CapabilityChipState(id: id, text: present ? yes : no, look: look, help: "")
}

private func batteryChip(_ reading: BatteryReading, words: L10n) -> CapabilityChipState {
    let look = CapabilityChipLook(ink: batteryTint(reading), on: false, absent: false)
    return CapabilityChipState(
        id: "battery",
        text: batteryChipText(reading, words: words),
        look: look,
        help: batteryHelp(reading, words: words)
    )
}

/// Live or muted, a click flips it; nil until the binding arms the microphone.
func micToggle(_ slot: ControllerSlot, words: L10n = .app) -> MicToggleState? {
    micStatusChip(slot, words: words).map { chip in
        MicToggleState(title: chip.label, muteOnClick: chip.on, help: chip.help)
    }
}

func motionRateText(_ hz: Int, words: L10n = .app) -> String? {
    hz > 0 ? words.motionHz(hz) : nil
}
