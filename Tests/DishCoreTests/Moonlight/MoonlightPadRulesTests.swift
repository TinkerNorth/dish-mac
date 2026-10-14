// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// The arrival a pad gets: the type Auto resolves to, the ceiling per type,
/// the buttons that follow, and when a held pad is worth a replug.
final class MoonlightPadRulesTests: XCTestCase {

    private let everything = MoonlightSourceCapabilities(
        rumble: true,
        triggerRumble: true,
        motion: true,
        touchpad: true,
        battery: true,
        lightbar: true
    )

    func testTheCeilingsAndTheSourceBits() {
        XCTAssertEqual(MoonlightPadRules.typeCeiling(MoonlightControllerType.xbox), 0x47)
        XCTAssertEqual(MoonlightPadRules.typeCeiling(MoonlightControllerType.nintendo), 0x47)
        XCTAssertEqual(MoonlightPadRules.typeCeiling(MoonlightControllerType.playStation), 0xFF)
        XCTAssertEqual(
            MoonlightPadRules.sourceBits(MoonlightSourceCapabilities()),
            MoonlightCapability.analogTriggers,
            "analog triggers always"
        )
        XCTAssertEqual(MoonlightPadRules.sourceBits(everything), 0xFF)
        XCTAssertEqual(MoonlightPadRules.sourceBits(MoonlightSourceCapabilities(rumble: true)), 0x03, "trigger rumble is its own feature")
    }

    func testAutoResolvesOnTheClientAndAStoredZeroIsAuto() {
        XCTAssertEqual(
            MoonlightPadRules.resolveType(picked: MoonlightControllerType.auto, sourceHasMotion: true),
            MoonlightControllerType.playStation
        )
        XCTAssertEqual(
            MoonlightPadRules.resolveType(picked: MoonlightControllerType.auto, sourceHasMotion: false),
            MoonlightControllerType.xbox
        )
        XCTAssertEqual(
            MoonlightPadRules.resolveType(picked: MoonlightControllerType.nintendo, sourceHasMotion: true),
            MoonlightControllerType.nintendo
        )
        XCTAssertEqual(MoonlightPadRules.migrateStoredType(0), MoonlightControllerType.auto, "0 is the wire's Unknown")
        XCTAssertEqual(MoonlightPadRules.migrateStoredType(2), MoonlightControllerType.playStation)
        XCTAssertEqual(MoonlightPadRules.migrateStoredType(255), MoonlightControllerType.auto)
        XCTAssertEqual(MoonlightPadRules.migrateStoredType(9), MoonlightControllerType.auto)
    }

    func testTheArrivalIsTheCeilingMetByTheSource() {
        let xbox = MoonlightPadRules.arrival(storedType: Int(MoonlightControllerType.xbox), source: everything)
        XCTAssertEqual(xbox, MoonlightAnnouncedPad(type: 1, capabilities: 0x47, supportedButtons: 0xF7FF))
        let playStation = MoonlightPadRules.arrival(storedType: Int(MoonlightControllerType.auto), source: everything)
        XCTAssertEqual(playStation, MoonlightAnnouncedPad(type: 2, capabilities: 0xFF, supportedButtons: 0x0010_F7FF))
        let bare = MoonlightPadRules.arrival(storedType: Int(MoonlightControllerType.playStation), source: MoonlightSourceCapabilities())
        XCTAssertEqual(bare.capabilities, 0x01, "a source with nothing declares nothing but its triggers")
        XCTAssertEqual(bare.supportedButtons, 0xF7FF)
        let rumbleOnly = MoonlightPadRules.arrival(
            storedType: Int(MoonlightControllerType.playStation),
            source: MoonlightSourceCapabilities(rumble: true)
        )
        XCTAssertEqual(rumbleOnly.capabilities, 0x03, "no motion claimed the source cannot send")
    }

    func testTheButtonSetLeavesTheMicMuteBitOutAndAddsTheTouchpadClick() {
        XCTAssertEqual(MoonlightPadRules.supportedButtons(capabilities: 0x03), 0xF7FF)
        XCTAssertEqual(
            MoonlightPadRules.supportedButtons(capabilities: 0x03 | MoonlightCapability.touchpad),
            0xF7FF | MoonlightButton.touchpad
        )
        XCTAssertEqual(MoonlightPadRules.frameButtonMask & MoonlightButton.reservedMicMute, 0, "never on the wire")
        XCTAssertEqual(MoonlightPadRules.frameButtonMask & MoonlightButton.home, MoonlightButton.home, "Guide passes")
        XCTAssertEqual(MoonlightPadRules.frameButtonMask & MoonlightButton.touchpad, MoonlightButton.touchpad)
        XCTAssertEqual(MoonlightPadRules.frameButtonMask & MoonlightButton.paddle1, 0, "no paddles from these pads")
    }

    func testAHeldPadIsReannouncedOnlyForAChangeTheHostReads() {
        let held = MoonlightAnnouncedPad(type: 2, capabilities: 0xFF, supportedButtons: 0x0010_F7FF)
        XCTAssertEqual(MoonlightPadRules.placement(held: nil, wanted: held), .acquire)
        XCTAssertEqual(MoonlightPadRules.placement(held: held, wanted: held), .keep)
        var otherType = held
        otherType.type = 1
        XCTAssertEqual(MoonlightPadRules.placement(held: held, wanted: otherType), .reannounce)
        var noMotion = held
        noMotion.capabilities = 0xFF & ~(MoonlightCapability.gyro | MoonlightCapability.accelerometer)
        XCTAssertEqual(MoonlightPadRules.placement(held: held, wanted: noMotion), .reannounce)
        var noLamp = held
        noLamp.capabilities = 0xFF & ~MoonlightCapability.rgbLed
        XCTAssertEqual(MoonlightPadRules.placement(held: held, wanted: noLamp), .keep, "a bit the host never reads is not worth a replug")
    }

    func testTouchesReachTheHostOnThePadPickOfATouchpadType() {
        XCTAssertTrue(MoonlightPadRules.touchReachesHost(pick: .pad, padHasTouchpad: true, type: MoonlightControllerType.playStation))
        XCTAssertFalse(
            MoonlightPadRules.touchReachesHost(pick: .pad, padHasTouchpad: true, type: MoonlightControllerType.xbox),
            "the type has no touchpad"
        )
        XCTAssertFalse(MoonlightPadRules.touchReachesHost(pick: .pad, padHasTouchpad: false, type: MoonlightControllerType.playStation))
        XCTAssertFalse(
            MoonlightPadRules.touchReachesHost(pick: .mouse, padHasTouchpad: true, type: MoonlightControllerType.playStation),
            "a Mouse pick puts no touches on the pad"
        )
        XCTAssertFalse(MoonlightPadRules.touchReachesHost(pick: .off, padHasTouchpad: true, type: MoonlightControllerType.playStation))
    }
}
