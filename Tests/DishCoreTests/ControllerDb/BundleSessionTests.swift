// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// Each message type counts under its kind, and every kind the client knows
/// has one.
final class BundleSessionTests: XCTestCase {

    func testEachSentTypeCountsUnderItsKind() {
        XCTAssertEqual(wireSentKind(ProtocolConstants.msgInput), .input)
        XCTAssertEqual(wireSentKind(ProtocolConstants.msgHeartbeat), .heartbeat)
        XCTAssertEqual(wireSentKind(ProtocolConstants.msgMotion), .motion)
        XCTAssertEqual(wireSentKind(ProtocolConstants.msgBattery), .battery)
        XCTAssertEqual(wireSentKind(ProtocolConstants.msgMicAudio), .mic)
    }

    func testTheTouchpadAndPointerFramesShareOneType() {
        XCTAssertEqual(wireSentKind(ProtocolConstants.msgTouchpad), .pointer)
    }

    func testAReceivedTypeIsNotASentKind() {
        XCTAssertNil(wireSentKind(ProtocolConstants.msgRumble))
        XCTAssertNil(wireSentKind(0xFFFF))
    }

    func testEachReceivedTypeCountsUnderItsKind() {
        let expected: [(UInt16, WireReceivedKind)] = [
            (ProtocolConstants.msgHeartbeatAck, .heartbeatAck),
            (ProtocolConstants.msgRumble, .rumble),
            (ProtocolConstants.msgLightbar, .lightbar),
            (ProtocolConstants.msgTriggerEffects, .triggerEffects),
            (ProtocolConstants.msgPlayerLeds, .playerLeds),
            (ProtocolConstants.msgMicLed, .micLed),
            (ProtocolConstants.msgSpeakerAudio, .speaker),
            (ProtocolConstants.msgHapticAudio, .haptic),
            (ProtocolConstants.msgSessionClose, .sessionClose)
        ]
        for (type, kind) in expected {
            XCTAssertEqual(wireReceivedKind(type), kind, "type \(type)")
        }
        XCTAssertEqual(Set(expected.map(\.1)), Set(WireReceivedKind.allCases))
    }

    func testASentTypeIsNotAReceivedKind() {
        XCTAssertNil(wireReceivedKind(ProtocolConstants.msgInput))
        XCTAssertNil(wireReceivedKind(0xFFFF))
    }

    func testATypeTheCatalogNamesIsItsSlug() {
        XCTAssertEqual(controllerTypeName(2, slugs: [2: "dualsense"]), "dualsense")
    }

    func testATypeTheCatalogDoesNotNameIsItsNumber() {
        XCTAssertEqual(controllerTypeName(3, slugs: [2: "dualsense"]), "3")
        XCTAssertEqual(controllerTypeName(2, slugs: [2: ""]), "2")
    }
}
