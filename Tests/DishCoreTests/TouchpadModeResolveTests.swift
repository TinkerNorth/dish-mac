// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// The ds4 > mouse > off ladder: a pick the path cannot carry declares off
/// and never crosses to the other routing (the desktops' cases, ported).
final class TouchpadModeResolveTests: XCTestCase {

    func testThePadPickNeedsATouchpadAndATypeThatRendersIt() {
        XCTAssertEqual(resolveTouchpadMode(pick: .pad, padHasTouchpad: true, typeOffersDs4: true, hostMouseControl: false), .ds4)
        XCTAssertEqual(
            resolveTouchpadMode(pick: .pad, padHasTouchpad: false, typeOffersDs4: true, hostMouseControl: true),
            .off,
            "a blocked pick never crosses to the other routing"
        )
        XCTAssertEqual(resolveTouchpadMode(pick: .pad, padHasTouchpad: true, typeOffersDs4: false, hostMouseControl: true), .off)
    }

    func testTheMousePickNeedsATouchpadAndTheHostsWord() {
        XCTAssertEqual(resolveTouchpadMode(pick: .mouse, padHasTouchpad: true, typeOffersDs4: false, hostMouseControl: true), .mouse)
        XCTAssertEqual(
            resolveTouchpadMode(pick: .mouse, padHasTouchpad: true, typeOffersDs4: true, hostMouseControl: false),
            .off,
            "no host word, no mouse, and never the pad render instead"
        )
        XCTAssertEqual(resolveTouchpadMode(pick: .mouse, padHasTouchpad: false, typeOffersDs4: true, hostMouseControl: true), .off)
    }

    func testOffIsOffWhateverTheCapabilities() {
        XCTAssertEqual(resolveTouchpadMode(pick: .off, padHasTouchpad: true, typeOffersDs4: true, hostMouseControl: true), .off)
    }

    func testTheWireNamesRoundTripAndUnknownNamesReadAsOff() {
        XCTAssertEqual(TouchpadPick(wireName: "ds4"), .pad)
        XCTAssertEqual(TouchpadPick(wireName: "mouse"), .mouse)
        XCTAssertEqual(TouchpadPick(wireName: "off"), .off)
        XCTAssertEqual(TouchpadPick(wireName: "banana"), .off)
        XCTAssertEqual(TouchpadPick(wireName: ""), .off)
        XCTAssertEqual(TouchpadPick.pickerOrder.map(\.wireName), ["off", "ds4", "mouse"])
        for name in ["off", "ds4", "mouse"] {
            XCTAssertTrue(isValidTouchpadPickName(name), name)
        }
        for name in ["", "DS4", "touchpad", "Mouse"] {
            XCTAssertFalse(isValidTouchpadPickName(name), "\(name) is not a wire word")
        }
    }

    func testATypeOffersThePadRenderWithDs4LineageOrAPreModesCatalog() {
        XCTAssertTrue(typeOffersDs4Touchpad(supported: true, modes: ["ds4"]))
        XCTAssertTrue(typeOffersDs4Touchpad(supported: true, modes: ["mouse", "ds4"]))
        XCTAssertTrue(typeOffersDs4Touchpad(supported: true, modes: []), "a pre-modes catalog is pad-capable")
        XCTAssertFalse(typeOffersDs4Touchpad(supported: true, modes: ["mouse"]), "a modes list without ds4 gates off")
        XCTAssertFalse(typeOffersDs4Touchpad(supported: false, modes: ["ds4"]))
        XCTAssertFalse(typeOffersDs4Touchpad(supported: false, modes: []))
    }
}
