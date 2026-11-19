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

    /// A satellite whose probe carries every direction.
    private let granting = HostAudioVerdict(mic: true, speaker: true, hapticAudio: true)

    func testAFullPadWithEverySwitchOnClaimsEveryActuatorButAudio() {
        let word = descriptorCaps(everything, ForwardingFlags(), host: granting)
        XCTAssertEqual(
            word,
            ProtocolConstants.capAnalogTriggers | ProtocolConstants.capRumble | ProtocolConstants.capMotion
                | ProtocolConstants.capLightbar | ProtocolConstants.capTriggerEffects | ProtocolConstants.capPlayerLeds
        )
        XCTAssertEqual(word & (ProtocolConstants.capMic | ProtocolConstants.capSpeaker | ProtocolConstants.capHapticAudio), 0)
    }

    func testTheExtendedButtonsClaimFollowsThePadAloneWithNoSwitch() {
        let everySwitchOff = ForwardingFlags(motion: false, touchpad: false, rumble: false, lightbar: false, mic: false, speaker: false)
        let sources = ControllerCapabilities(hasExtendedButtons: true)
        XCTAssertNotEqual(descriptorCaps(sources, everySwitchOff, host: .none) & ProtocolConstants.capExtendedButtons, 0)
        XCTAssertEqual(descriptorCaps(everything, ForwardingFlags(), host: granting) & ProtocolConstants.capExtendedButtons, 0)
    }

    func testTheAudioCapsFollowTheAudioFunctionAndTheControllersSwitches() {
        let dualSense = ControllerCapabilities(hasRumble: true, hasMic: true, hasSpeaker: true, hasHapticLanes: true)
        let on = descriptorCaps(dualSense, ForwardingFlags(mic: true, speaker: true), host: granting)
        XCTAssertNotEqual(on & ProtocolConstants.capMic, 0)
        XCTAssertNotEqual(on & ProtocolConstants.capSpeaker, 0)
        XCTAssertNotEqual(on & ProtocolConstants.capHapticAudio, 0)
        XCTAssertNotEqual(on & ProtocolConstants.capRumble, 0, "rumble rides beside the lanes; the host decides which rendering")
        let defaults = descriptorCaps(dualSense, ForwardingFlags(), host: granting)
        XCTAssertEqual(defaults & ProtocolConstants.capMic, 0, "the mic is off until asked")
        XCTAssertNotEqual(defaults & ProtocolConstants.capSpeaker, 0)
        let speakerOff = descriptorCaps(dualSense, ForwardingFlags(mic: true, speaker: false), host: granting)
        XCTAssertEqual(
            speakerOff & (ProtocolConstants.capSpeaker | ProtocolConstants.capHapticAudio),
            0,
            "the speaker switch covers the lanes"
        )
        XCTAssertNotEqual(speakerOff & ProtocolConstants.capMic, 0)
        let headset = ControllerCapabilities(hasMic: true, hasSpeaker: true)
        XCTAssertEqual(
            descriptorCaps(headset, ForwardingFlags(mic: true), host: granting) & ProtocolConstants.capHapticAudio,
            0,
            "no lanes, no haptics cap"
        )
    }

    func testTheAudioCapsWaitForTheHostsWordAndLeaveWithARefusedEndpoint() {
        let dualSense = ControllerCapabilities(hasRumble: true, hasMic: true, hasSpeaker: true, hasHapticLanes: true)
        let on = ForwardingFlags(mic: true, speaker: true)
        let audio = ProtocolConstants.capMic | ProtocolConstants.capSpeaker | ProtocolConstants.capHapticAudio
        XCTAssertEqual(descriptorCaps(dualSense, on, host: .none) & audio, 0, "no host word, no audio cap")
        let micAlone = HostAudioVerdict(mic: true, speaker: false, hapticAudio: false)
        XCTAssertEqual(descriptorCaps(dualSense, on, host: micAlone) & audio, ProtocolConstants.capMic)
        let refusedOutput = descriptorCaps(dualSense, on, host: granting, playbackRefused: true)
        XCTAssertEqual(refusedOutput & audio, ProtocolConstants.capMic, "a refused output withdraws both lanes")
        let refusedInput = descriptorCaps(dualSense, on, host: granting, captureRefused: true)
        XCTAssertEqual(refusedInput & audio, ProtocolConstants.capSpeaker | ProtocolConstants.capHapticAudio)
        XCTAssertNotEqual(refusedOutput & ProtocolConstants.capRumble, 0, "rumble is the fallback and stays")
    }

    func testAnalogTriggersAreAlwaysClaimed() {
        XCTAssertEqual(descriptorCaps(.none, ForwardingFlags(), host: .none), ProtocolConstants.capAnalogTriggers)
        XCTAssertEqual(
            descriptorCaps(.none, ForwardingFlags(motion: false, touchpad: false, rumble: false, lightbar: false), host: .none),
            ProtocolConstants.capAnalogTriggers
        )
    }

    func testASwitchedOffFeatureIsNotClaimed() {
        XCTAssertEqual(descriptorCaps(everything, ForwardingFlags(motion: false), host: granting) & ProtocolConstants.capMotion, 0)
        XCTAssertEqual(descriptorCaps(everything, ForwardingFlags(rumble: false), host: granting) & ProtocolConstants.capRumble, 0)
        XCTAssertEqual(descriptorCaps(everything, ForwardingFlags(lightbar: false), host: granting) & ProtocolConstants.capLightbar, 0)
    }

    func testMissingHardwareIsNeverClaimedWhateverTheSwitches() {
        let padWithoutImu = ControllerCapabilities(hasRumble: true, hasLightbar: true)
        XCTAssertEqual(descriptorCaps(padWithoutImu, ForwardingFlags(), host: .none) & ProtocolConstants.capMotion, 0)
        XCTAssertEqual(descriptorCaps(padWithoutImu, ForwardingFlags(), host: .none) & ProtocolConstants.capTriggerEffects, 0)
        XCTAssertEqual(descriptorCaps(padWithoutImu, ForwardingFlags(), host: .none) & ProtocolConstants.capPlayerLeds, 0)
    }

    func testTheFeedbackCapsFollowTheHardwareAlone() {
        let dualSense = ControllerCapabilities(hasTriggerEffects: true, hasPlayerLeds: true)
        let word = descriptorCaps(dualSense, ForwardingFlags(motion: false, touchpad: false, rumble: false, lightbar: false), host: .none)
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

    func testTheTouchpadModeFollowsThePickThroughTheLadder() {
        let withPad = ControllerCapabilities(hasTouchpad: true)
        let mouse = ForwardingFlags(touchpadPick: .mouse)
        XCTAssertEqual(descriptorTouchpadMode(withPad, mouse, typeOffersDs4: true, hostMouseControl: true), .mouse)
        XCTAssertEqual(descriptorTouchpadMode(withPad, mouse, typeOffersDs4: true, hostMouseControl: false), .off, "no host word, no mouse")
        XCTAssertEqual(
            descriptorTouchpadMode(withPad, ForwardingFlags(), typeOffersDs4: false, hostMouseControl: true),
            .off,
            "no ds4 render"
        )
        let globalOff = ForwardingFlags(touchpad: false, touchpadPick: .mouse)
        XCTAssertEqual(
            descriptorTouchpadMode(withPad, globalOff, typeOffersDs4: true, hostMouseControl: true),
            .off,
            "Settings outranks the pick"
        )
        XCTAssertEqual(descriptorTouchpadMode(.none, mouse, typeOffersDs4: true, hostMouseControl: true), .off, "no touchpad, no mouse")
    }

    func testTheCatalogsWordOnTheTypesTouchpad() throws {
        XCTAssertTrue(typeOffersDs4Touchpad(in: nil, type: 2), "no catalog refuses nothing")
        let catalog = try JSONDecoder().decode(CatalogDTO.self, from: Data(FakeSatelliteRest.catalogJSON.utf8))
        XCTAssertTrue(typeOffersDs4Touchpad(in: catalog, type: 1), "the DualShock 4 type offers the pad render")
        XCTAssertFalse(typeOffersDs4Touchpad(in: catalog, type: 0), "the Xbox type has no touchpad")
        XCTAssertTrue(typeOffersDs4Touchpad(in: catalog, type: 9), "a type the catalog does not name refuses nothing")
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
