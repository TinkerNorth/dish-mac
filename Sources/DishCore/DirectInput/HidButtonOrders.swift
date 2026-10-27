// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The order a generic HID pad declares its buttons in, as the desktops'
// `UsbHidLayout.h` maps them: one wire button per declared index, and the
// index of a button that drives a trigger named apart, since a trigger is a
// level and not a bit.

import Foundation

public enum HidButtonOrder: Equatable, Sendable {
    /// DirectInput's A B X Y LB RB Back Start L3 R3 Guide.
    case western
    /// Y B A X L R ZL ZR Minus Plus L3 R3 Home Capture, by position.
    case nintendoSwitch
    /// 8BitDo's D-input A B Heart X Y (none) Z C L R Select Start Heart L3 R3.
    case eightBitDo
    /// Triangle Circle Cross Square L2 R2 L1 R1 Select Start, by position.
    case playStationClassic
}

/// The declared indices of the two buttons that are the triggers.
struct DigitalTriggers: Equatable {
    let left: Int
    let right: Int
}

struct HidButtonOrderMap: Equatable {
    /// One entry per declared index; nil where the wire has no bit for it.
    let buttons: [WireButton?]
    let triggers: DigitalTriggers?

    func button(at index: Int) -> WireButton? {
        index < buttons.count ? buttons[index] : nil
    }
}

let westernOrderMap = HidButtonOrderMap(
    buttons: [.faceA, .faceB, .faceX, .faceY, .leftShoulder, .rightShoulder, .back, .start, .leftThumb, .rightThumb, .guide],
    triggers: nil
)

/// Remapped by position to match the Switch report decoder; Capture has no
/// XUSB bit.
let switchOrderMap = HidButtonOrderMap(
    buttons: [.faceX, .faceA, .faceB, .faceY, .leftShoulder, .rightShoulder, nil, nil, .back, .start, .leftThumb, .rightThumb, .guide],
    triggers: DigitalTriggers(left: 6, right: 7)
)

/// Z and C are the shoulders, L and R the triggers, and Heart sits at 3 or
/// 13 by firmware.
let eightBitDoOrderMap = HidButtonOrderMap(
    buttons: [
        .faceA, .faceB, .guide, .faceX, .faceY, nil, .leftShoulder, .rightShoulder, nil, nil,
        .back, .start, .guide, .leftThumb, .rightThumb
    ],
    triggers: DigitalTriggers(left: 8, right: 9)
)

let playStationClassicOrderMap = HidButtonOrderMap(
    buttons: [.faceY, .faceB, .faceA, .faceX, nil, nil, .leftShoulder, .rightShoulder, .back, .start],
    triggers: DigitalTriggers(left: 4, right: 5)
)

func buttonOrderMap(_ order: HidButtonOrder) -> HidButtonOrderMap {
    switch order {
    case .western: westernOrderMap
    case .nintendoSwitch: switchOrderMap
    case .eightBitDo: eightBitDoOrderMap
    case .playStationClassic: playStationClassicOrderMap
    }
}

/// A hat's eight directions clockwise from north.
let hatDirections: [WireButtonWord] = [
    [.dpadUp], [.dpadUp, .dpadRight], [.dpadRight], [.dpadDown, .dpadRight],
    [.dpadDown], [.dpadDown, .dpadLeft], [.dpadLeft], [.dpadUp, .dpadLeft]
]
