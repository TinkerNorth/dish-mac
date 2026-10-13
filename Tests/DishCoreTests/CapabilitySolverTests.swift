// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// available = input ∩ link ∩ type ∩ host, and the FIRST failing layer is the
/// one named, because it is the one whose fix is actionable.
final class CapabilitySolverTests: XCTestCase {

    /// Every layer carries everything; each test then breaks exactly one thing.
    private func everythingCarries() -> CapabilityInputs {
        var inputs = CapabilityInputs()
        inputs.padMotion = true
        inputs.padTouchpad = true
        inputs.padRumble = true
        inputs.padLightbar = true
        inputs.padTriggerEffects = true
        inputs.padPlayerLeds = true
        inputs.padMic = true
        inputs.padSpeaker = true
        inputs.linkRoutesMouse = true
        inputs.typeResolved = true
        inputs.typeMotion = true
        inputs.typeTouchpad = true
        inputs.typeRumble = true
        inputs.typeLightbar = true
        inputs.typeTriggerEffects = true
        inputs.typePlayerLeds = true
        inputs.typeMic = true
        inputs.typeSpeaker = true
        inputs.hostResolved = true
        inputs.hostMouseControl = true
        inputs.hostRumble = true
        inputs.hostMic = true
        inputs.hostSpeaker = true
        inputs.userMicOn = true
        inputs.userTouchpadPick = .pad
        return inputs
    }

    private func row(_ feature: CapFeature, _ inputs: CapabilityInputs) throws -> CapabilityRow {
        try XCTUnwrap(solveCapabilities(inputs).first { $0.feature == feature })
    }

    // MARK: - The shape

    func testTheElevenFeaturesComeBackInTheFixedRenderOrder() {
        let order = solveCapabilities(everythingCarries()).map(\.feature)
        XCTAssertEqual(order, [
            .gamepad, .triggers, .motion, .touchpad, .mouse, .rumble, .lightbar, .triggerEffects, .playerLeds, .mic, .speaker
        ])
        XCTAssertEqual(order, CapFeature.allCases, "a row inserted in the middle would reshuffle every table")
    }

    func testEverythingCarryingReadsAvailableAndBlamesNobody() {
        for row in solveCapabilities(everythingCarries()) where row.feature != .mouse {
            XCTAssertEqual(row.verdict, .available, "\(row.feature)")
            XCTAssertNil(row.failingLayer, "\(row.feature)")
            XCTAssertTrue(row.inputOk && row.linkOk && row.typeOk && row.hostOk, "\(row.feature)")
        }
    }

    // MARK: - One layer at a time

    func testAPadWithNoGyroFailsMotionOnTheInputLayer() throws {
        var inputs = everythingCarries()
        inputs.padMotion = false
        let motion = try row(.motion, inputs)
        XCTAssertEqual(motion.verdict, .unavailable)
        XCTAssertEqual(motion.failingLayer, .input)
        XCTAssertFalse(motion.inputOk)
        XCTAssertTrue(motion.linkOk && motion.typeOk && motion.hostOk, "later layers still report their own truth")
    }

    func testThePadWithoutATouchpadFailsBothTheTouchpadAndTheMouseAtTheInput() throws {
        var inputs = everythingCarries()
        inputs.padTouchpad = false
        inputs.userTouchpadPick = .mouse
        XCTAssertEqual(try row(.touchpad, inputs).failingLayer, .input)
        XCTAssertEqual(try row(.mouse, inputs).failingLayer, .input)
    }

    func testTheLinkRefusesOnlyTheMouseItDoesNotRoute() throws {
        var inputs = everythingCarries()
        inputs.linkRoutesMouse = false
        inputs.userTouchpadPick = .mouse
        let mouse = try row(.mouse, inputs)
        XCTAssertEqual(mouse.verdict, .unavailable)
        XCTAssertEqual(mouse.failingLayer, .link)
        XCTAssertTrue(mouse.inputOk, "the pad still has the touchpad")
        for feature in CapFeature.allCases where feature != .mouse {
            XCTAssertTrue(try row(feature, inputs).linkOk, "\(feature)")
        }
    }

    func testTheLinkRefusesThePadsAudioItHasNoFunctionFor() throws {
        var inputs = everythingCarries()
        inputs.linkRoutesMic = false
        inputs.linkRoutesSpeaker = false
        let mic = try row(.mic, inputs)
        XCTAssertEqual(mic.verdict, .unavailable)
        XCTAssertEqual(mic.failingLayer, .link)
        XCTAssertEqual(try row(.speaker, inputs).failingLayer, .link)
        XCTAssertEqual(try row(.gamepad, inputs).verdict, .available, "the link refuses nothing else")
        XCTAssertEqual(try row(.mic, everythingCarries()).verdict, .available, "a link that never looked refuses nothing")
    }

    func testAnXboxTypeFailsTheSonyFeaturesOnTheTypeLayer() throws {
        var inputs = everythingCarries()
        inputs.typeMotion = false
        inputs.typeTouchpad = false
        inputs.typeLightbar = false
        inputs.typeTriggerEffects = false
        inputs.typePlayerLeds = false
        inputs.typeMic = false
        inputs.typeSpeaker = false
        for feature in [CapFeature.motion, .touchpad, .lightbar, .triggerEffects, .playerLeds, .mic, .speaker] {
            let solved = try row(feature, inputs)
            XCTAssertEqual(solved.verdict, .unavailable, "\(feature)")
            XCTAssertEqual(solved.failingLayer, .type, "\(feature)")
        }
        XCTAssertEqual(try row(.rumble, inputs).verdict, .available)
        XCTAssertEqual(try row(.gamepad, inputs).verdict, .available)
    }

    func testAHostWithoutRumbleOrMouseControlFailsThemOnTheHostLayer() throws {
        var inputs = everythingCarries()
        inputs.hostRumble = false
        inputs.hostMouseControl = false
        inputs.userTouchpadPick = .mouse
        XCTAssertEqual(try row(.rumble, inputs).failingLayer, .host)
        XCTAssertEqual(try row(.mouse, inputs).failingLayer, .host)
        XCTAssertEqual(try row(.motion, inputs).verdict, .available, "the host layer never refuses motion")
    }

    func testAnUnprobedHostCarriesNoAudio() throws {
        var inputs = everythingCarries()
        inputs.hostMic = false
        inputs.hostSpeaker = false
        XCTAssertEqual(try row(.mic, inputs).failingLayer, .host)
        XCTAssertEqual(try row(.speaker, inputs).failingLayer, .host)
    }

    // MARK: - Off is not unavailable

    func testAUserSwitchReadsOffNeverUnavailable() throws {
        var inputs = everythingCarries()
        inputs.userMotionOn = false
        inputs.userRumbleOn = false
        inputs.userLightbarOn = false
        inputs.userMicOn = false
        inputs.userSpeakerOn = false
        inputs.userTouchpadPick = .off
        for feature in [CapFeature.motion, .rumble, .lightbar, .mic, .speaker, .touchpad, .mouse] {
            let solved = try row(feature, inputs)
            XCTAssertEqual(solved.verdict, .off, "\(feature)")
            XCTAssertNil(solved.failingLayer, "\(feature)")
        }
        XCTAssertEqual(try row(.triggerEffects, inputs).verdict, .available, "no user gate")
        XCTAssertEqual(try row(.playerLeds, inputs).verdict, .available, "no user gate")
    }

    func testTheTouchpadPickRoutesOneOfTheTwoRows() throws {
        var inputs = everythingCarries()
        inputs.userTouchpadPick = .pad
        XCTAssertEqual(try row(.touchpad, inputs).verdict, .available)
        XCTAssertEqual(try row(.mouse, inputs).verdict, .off)
        inputs.userTouchpadPick = .mouse
        XCTAssertEqual(try row(.touchpad, inputs).verdict, .off)
        XCTAssertEqual(try row(.mouse, inputs).verdict, .available)
    }

    func testASwitchOffAnUnavailableFeatureStillReadsUnavailable() throws {
        var inputs = everythingCarries()
        inputs.padMotion = false
        inputs.userMotionOn = false
        XCTAssertEqual(try row(.motion, inputs).verdict, .unavailable, "unavailable wins over off")
    }

    // MARK: - Pending

    func testAnUnresolvedHostOrTypeReadsPendingAndRefusesNothing() throws {
        var noHost = everythingCarries()
        noHost.hostResolved = false
        noHost.hostRumble = false
        XCTAssertTrue(capabilitiesPending(noHost))
        for row in solveCapabilities(noHost) {
            XCTAssertEqual(row.verdict, .pending, "\(row.feature)")
            XCTAssertNil(row.failingLayer)
            XCTAssertTrue(row.hostOk, "an unread host refuses nothing: \(row.feature)")
        }
        var noType = everythingCarries()
        noType.typeResolved = false
        noType.typeMotion = false
        XCTAssertTrue(capabilitiesPending(noType))
        XCTAssertTrue(try row(.motion, noType).typeOk, "an unread catalog refuses nothing")
        XCTAssertFalse(capabilitiesPending(everythingCarries()))
    }

    func testTheDefaultsRefuseTheRareActuatorsAndCarryRumble() throws {
        var inputs = CapabilityInputs()
        inputs.typeResolved = true
        inputs.typeRumble = true
        inputs.hostResolved = true
        inputs.hostRumble = true
        XCTAssertEqual(try row(.rumble, inputs).verdict, .available, "an unknown pad is assumed to have motors")
        XCTAssertEqual(try row(.triggerEffects, inputs).failingLayer, .input)
        XCTAssertEqual(try row(.playerLeds, inputs).failingLayer, .input)
        XCTAssertEqual(try row(.mic, inputs).failingLayer, .input)
    }
}
