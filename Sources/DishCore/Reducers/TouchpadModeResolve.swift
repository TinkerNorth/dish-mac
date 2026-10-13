// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The ds4 > mouse > off ladder that turns the user's pick for a controller's
// touchpad into the `touchpadMode` its descriptor declares (a port of
// dish-linux TouchpadModeResolve.h). A pick the path cannot carry declares
// off rather than a request the satellite would dead-letter, and a blocked
// pick never falls back to the other routing: the pad render is a per-type
// concern, mouse control is host-injected.

import Foundation

public extension TouchpadPick {
    /// The stored and wire name, the satellite's own: `"off"`, `"ds4"`,
    /// `"mouse"`. An unknown name reads as off, the server's default too.
    init(wireName: String) {
        switch wireName {
        case "ds4": self = .pad
        case "mouse": self = .mouse
        default: self = .off
        }
    }

    var wireName: String {
        switch self {
        case .off: "off"
        case .pad: "ds4"
        case .mouse: "mouse"
        }
    }

    /// The picker's order, pinned so the list is stable across builds.
    static let pickerOrder: [TouchpadPick] = [.off, .pad, .mouse]
}

/// Only a genuine wire string survives the round trip unchanged.
public func isValidTouchpadPickName(_ name: String) -> Bool {
    TouchpadPick(wireName: name).wireName == name
}

/// A touchpad-bearing type with no `ds4` lineage gates the pad render off. A
/// pre-modes catalog omits `modes`; empty therefore means pad-capable.
public func typeOffersDs4Touchpad(supported: Bool, modes: [String]) -> Bool {
    supported && (modes.isEmpty || modes.contains(TouchpadPick.pad.wireName))
}

/// The mode a descriptor declares for the pick: the pad render needs a
/// touchpad and a type that offers it; the mouse needs a touchpad and a host
/// that advertises mouse control; off is off.
public func resolveTouchpadMode(pick: TouchpadPick, padHasTouchpad: Bool, typeOffersDs4: Bool, hostMouseControl: Bool) -> TouchpadMode {
    switch pick {
    case .pad: padHasTouchpad && typeOffersDs4 ? .ds4 : .off
    case .mouse: padHasTouchpad && hostMouseControl ? .mouse : .off
    case .off: .off
    }
}
