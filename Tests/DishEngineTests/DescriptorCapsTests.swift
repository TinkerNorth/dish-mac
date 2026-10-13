// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// The descriptor claims what the pad has AND the user allows: a cap is a
/// promise the matching path lands.
final class DescriptorCapsTests: XCTestCase {

    private let everything = ControllerCapabilities(
        hasMotion: true,
        hasTouchpad: true,
        hasRumble: true,
        hasLightbar: true,
        hasBattery: true,
        hasTriggerEffects: true,
        hasPlayerLeds: true
    )

    func testAFullPadWithEverySwitchOnClaimsEveryActuatorButAudio() {
        let word = descriptorCaps(everything, ForwardingFlags())
        XCTAssertEqual(
            word,
            ProtocolConstants.capAnalogTriggers | ProtocolConstants.capRumble | ProtocolConstants.capMotion
                | ProtocolConstants.capLightbar | ProtocolConstants.capTriggerEffects | ProtocolConstants.capPlayerLeds
        )
        XCTAssertEqual(word & (ProtocolConstants.capMic | ProtocolConstants.capSpeaker | ProtocolConstants.capHapticAudio), 0)
    }

    func testTheAudioCapsFollowTheAudioFunctionAndTheControllersSwitches() {
        let dualSense = ControllerCapabilities(hasRumble: true, hasMic: true, hasSpeaker: true, hasHapticLanes: true)
        let on = descriptorCaps(dualSense, ForwardingFlags(mic: true, speaker: true))
        XCTAssertNotEqual(on & ProtocolConstants.capMic, 0)
        XCTAssertNotEqual(on & ProtocolConstants.capSpeaker, 0)
        XCTAssertNotEqual(on & ProtocolConstants.capHapticAudio, 0)
        XCTAssertNotEqual(on & ProtocolConstants.capRumble, 0, "rumble rides beside the lanes; the host decides which rendering")
        let defaults = descriptorCaps(dualSense, ForwardingFlags())
        XCTAssertEqual(defaults & ProtocolConstants.capMic, 0, "the mic is off until asked")
        XCTAssertNotEqual(defaults & ProtocolConstants.capSpeaker, 0)
        let speakerOff = descriptorCaps(dualSense, ForwardingFlags(mic: true, speaker: false))
        XCTAssertEqual(
            speakerOff & (ProtocolConstants.capSpeaker | ProtocolConstants.capHapticAudio),
            0,
            "the speaker switch covers the lanes"
        )
        XCTAssertNotEqual(speakerOff & ProtocolConstants.capMic, 0)
        let headset = ControllerCapabilities(hasMic: true, hasSpeaker: true)
        XCTAssertEqual(
            descriptorCaps(headset, ForwardingFlags(mic: true)) & ProtocolConstants.capHapticAudio,
            0,
            "no lanes, no haptics cap"
        )
    }

    func testAnalogTriggersAreAlwaysClaimed() {
        XCTAssertEqual(descriptorCaps(.none, ForwardingFlags()), ProtocolConstants.capAnalogTriggers)
        XCTAssertEqual(
            descriptorCaps(.none, ForwardingFlags(motion: false, touchpad: false, rumble: false, lightbar: false)),
            ProtocolConstants.capAnalogTriggers
        )
    }

    func testASwitchedOffFeatureIsNotClaimed() {
        XCTAssertEqual(descriptorCaps(everything, ForwardingFlags(motion: false)) & ProtocolConstants.capMotion, 0)
        XCTAssertEqual(descriptorCaps(everything, ForwardingFlags(rumble: false)) & ProtocolConstants.capRumble, 0)
        XCTAssertEqual(descriptorCaps(everything, ForwardingFlags(lightbar: false)) & ProtocolConstants.capLightbar, 0)
    }

    func testMissingHardwareIsNeverClaimedWhateverTheSwitches() {
        let padWithoutImu = ControllerCapabilities(hasRumble: true, hasLightbar: true)
        XCTAssertEqual(descriptorCaps(padWithoutImu, ForwardingFlags()) & ProtocolConstants.capMotion, 0)
        XCTAssertEqual(descriptorCaps(padWithoutImu, ForwardingFlags()) & ProtocolConstants.capTriggerEffects, 0)
        XCTAssertEqual(descriptorCaps(padWithoutImu, ForwardingFlags()) & ProtocolConstants.capPlayerLeds, 0)
    }

    func testTheFeedbackCapsFollowTheHardwareAlone() {
        let dualSense = ControllerCapabilities(hasTriggerEffects: true, hasPlayerLeds: true)
        let word = descriptorCaps(dualSense, ForwardingFlags(motion: false, touchpad: false, rumble: false, lightbar: false))
        XCTAssertNotEqual(word & ProtocolConstants.capTriggerEffects, 0)
        XCTAssertNotEqual(word & ProtocolConstants.capPlayerLeds, 0)
    }

    func testTheTouchpadModeIsThePadRenderOnlyWhenPresentAndOn() {
        let withPad = ControllerCapabilities(hasTouchpad: true)
        XCTAssertEqual(descriptorTouchpadMode(withPad, ForwardingFlags()), .ds4)
        XCTAssertEqual(descriptorTouchpadMode(withPad, ForwardingFlags(touchpad: false)), .off)
        XCTAssertEqual(descriptorTouchpadMode(.none, ForwardingFlags()), .off)
    }

    // MARK: - The type a pad is emulated as

    private func catalog() throws -> CatalogDTO {
        try JSONDecoder().decode(CatalogDTO.self, from: Data(FakeSatelliteRest.catalogJSON.utf8))
    }

    func testEachFamilyIsEmulatedAsItself() throws {
        let types = try catalog()
        XCTAssertEqual(preferredControllerType(in: types, for: .dualSense), 2)
        XCTAssertEqual(preferredControllerType(in: types, for: .dualShock4), 1)
        XCTAssertEqual(preferredControllerType(in: types, for: .xbox), 0)
    }

    func testAnUnknownFamilyTakesTheFirstOfferedType() throws {
        XCTAssertEqual(try preferredControllerType(in: catalog(), for: .other), 0)
    }

    func testAFamilyTheCatalogDoesNotEmulateFallsBackInOrder() throws {
        var types = try catalog()
        types.controllerTypes.removeAll { $0.emulates?.sdlType == "ps5" }
        XCTAssertEqual(preferredControllerType(in: types, for: .dualSense), 1, "a DualSense settles for the DualShock 4 type")
        types.controllerTypes.removeAll { $0.emulates?.sdlType == "ps4" }
        XCTAssertEqual(preferredControllerType(in: types, for: .dualSense), 0, "then for whatever is first")
    }

    func testALegacyCatalogWithoutEmulatesTakesTheFirstType() throws {
        var types = try catalog()
        for index in types.controllerTypes.indices {
            types.controllerTypes[index].emulates = nil
        }
        XCTAssertEqual(preferredControllerType(in: types, for: .dualSense), 0)
    }

    func testNoCatalogMeansTheLegacyXboxTarget() {
        XCTAssertEqual(preferredControllerType(in: nil, for: .dualSense), Int(ProtocolConstants.controllerTypeXbox))
        XCTAssertEqual(preferredControllerType(in: CatalogDTO(), for: .xbox), Int(ProtocolConstants.controllerTypeXbox))
    }
}
