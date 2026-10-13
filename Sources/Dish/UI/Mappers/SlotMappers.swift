// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import Foundation
import SwiftUI

/// The connections a slot may bind to: every one not already bound to a
/// different slot.
func bindableConnections(for slot: ControllerSlot, in connections: [ConnectionSummary]) -> [ConnectionSummary] {
    connections.filter { $0.boundSlotId == nil || $0.boundSlotId == slot.id }
}

/// Where a slot's input goes, with the bound server's state in brackets
/// unless it is plainly online.
func bindLabel(_ bound: ConnectionSummary?, words: L10n = .app) -> String {
    guard let bound else { return words.unbound }
    switch bound.live {
    case .connected: return words.boundTo(bound.label)
    case .unstable: return words.boundUnsteady(bound.label)
    case .connecting: return words.boundConnecting(bound.label)
    case .ready: return words.boundReady(bound.label)
    case .saved, .found, .stale: return words.boundOffline(bound.label)
    }
}

func slotSubtitle(_ slot: ControllerSlot, words: L10n = .app) -> String {
    words.gamepadSubtitle(bindLabel(slot.boundStatus, words: words))
}

/// An unbound slot shows the muted dot and the plain satellite glyph.
func slotDotColor(_ slot: ControllerSlot) -> Color {
    guard let bound = slot.boundStatus else { return DishTheme.muted }
    return linkDotColor(bound.live)
}

func slotIconState(_ slot: ControllerSlot) -> BrandIconState {
    brandIconState(for: slot.boundStatus?.live ?? .saved)
}

func bindButtonTitle(expanded: Bool, words: L10n = .app) -> String {
    expanded ? words.close : words.bind
}

/// One capability pill. Three states a player can tell apart: available and
/// on, available but off in Settings, and absent from the hardware.
struct CapabilityChipModel: Equatable {
    let label: String
    let on: Bool
    let available: Bool
    let help: String
}

/// The chips for a slot. Motion always shows, present or explicitly absent;
/// touchpad, rumble and the light bar only when the pad has them.
func capabilityChips(_ caps: ControllerCapabilities, _ flags: ForwardingFlags, words: L10n = .app) -> [CapabilityChipModel] {
    let optional: [(present: Bool, label: String, feature: String, on: Bool)] = [
        (caps.hasTouchpad, words.touchpad, words.touchpad, flags.touchpad),
        (caps.hasRumble, words.rumble, words.rumble, flags.rumble),
        (caps.hasLightbar, words.lightbar, words.lightBar, flags.lightbar)
    ]
    return [motionChip(present: caps.hasMotion, on: flags.motion, words: words)]
        + optional.filter(\.present).map { detectedChip($0.label, feature: $0.feature, on: $0.on, words: words) }
}

private func motionChip(present: Bool, on: Bool, words: L10n) -> CapabilityChipModel {
    guard present else {
        return CapabilityChipModel(label: words.noGyro, on: false, available: false, help: words.motionUnavailableHelp)
    }
    return detectedChip(words.gyro, feature: words.motion, on: on, words: words)
}

private func detectedChip(_ label: String, feature: String, on: Bool, words: L10n) -> CapabilityChipModel {
    CapabilityChipModel(
        label: label,
        on: on,
        available: true,
        help: on ? words.detectedOn(feature) : words.detectedOff(feature)
    )
}
