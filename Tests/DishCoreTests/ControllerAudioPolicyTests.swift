// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// The host's verdict folded as dish-android folds it, the voices and the
/// capture decided as the desktops decide them, and the one mic chip.
final class ControllerAudioPolicyTests: XCTestCase {

    private func everything() -> AudioFacts {
        AudioFacts(
            routeMic: true,
            routeSpeaker: true,
            routeHapticLanes: true,
            micOn: true,
            speakerOn: true,
            host: HostAudioVerdict(mic: true, speaker: true, hapticAudio: true),
            live: true,
            micPermitted: true,
            muted: false
        )
    }

    // MARK: - The host's verdict

    func testAPresentBlockIsTheVerdictAlreadyAndedWithEnabled() {
        XCTAssertEqual(
            hostAudioVerdict(blockPresent: true, enabled: true, mic: true, speaker: false, hapticAudio: true, anyBackendAudio: false),
            HostAudioVerdict(mic: true, speaker: false, hapticAudio: true)
        )
        XCTAssertEqual(
            hostAudioVerdict(blockPresent: true, enabled: false, mic: true, speaker: true, hapticAudio: true, anyBackendAudio: true),
            .none,
            "the host's own switch off carries nothing"
        )
    }

    func testAnOlderSatelliteCarriesAudioWhereABackendCanAndNeverTheLanes() {
        XCTAssertEqual(
            hostAudioVerdict(blockPresent: false, enabled: false, mic: false, speaker: false, hapticAudio: false, anyBackendAudio: true),
            HostAudioVerdict(mic: true, speaker: true, hapticAudio: false)
        )
        XCTAssertEqual(
            hostAudioVerdict(blockPresent: false, enabled: false, mic: false, speaker: false, hapticAudio: false, anyBackendAudio: false),
            .none
        )
    }

    // MARK: - The plan

    func testEverythingInPlaceCapturesPlaysBothLanesAndAdvertisesAllThree() {
        let plan = audioPlan(everything())
        XCTAssertTrue(plan.capture && plan.speakerVoice && plan.hapticVoice)
        XCTAssertTrue(plan.capMic && plan.capSpeaker && plan.capHapticAudio)
        XCTAssertTrue(plan.micArmed)
    }

    func testTheCapsFollowTheRouteAndTheSwitchNotTheHost() {
        var facts = everything()
        facts.host = .none
        let plan = audioPlan(facts)
        XCTAssertTrue(plan.capMic && plan.capSpeaker && plan.capHapticAudio, "a cap says what the client can do")
        XCTAssertFalse(plan.capture || plan.speakerVoice || plan.hapticVoice, "nothing runs until the host will feed it")
        XCTAssertFalse(plan.micArmed)
    }

    func testTheSpeakerSwitchCoversTheHapticsLanes() {
        var facts = everything()
        facts.speakerOn = false
        let plan = audioPlan(facts)
        XCTAssertFalse(plan.capSpeaker || plan.capHapticAudio || plan.speakerVoice || plan.hapticVoice)
        XCTAssertTrue(plan.capMic && plan.capture, "the mic is its own switch")
    }

    func testMuteStopsCaptureButKeepsTheMicArmedAndAdvertised() {
        var facts = everything()
        facts.muted = true
        let plan = audioPlan(facts)
        XCTAssertFalse(plan.capture)
        XCTAssertTrue(plan.micArmed, "the chip shows it muted, not hidden")
        XCTAssertTrue(plan.capMic)
    }

    func testNoPermissionNoRouteOrNoSessionArmsNothing() {
        var noPermission = everything()
        noPermission.micPermitted = false
        XCTAssertFalse(audioPlan(noPermission).micArmed)
        var noRoute = everything()
        noRoute.routeMic = false
        noRoute.routeSpeaker = false
        noRoute.routeHapticLanes = false
        XCTAssertEqual(audioPlan(noRoute), .silent)
        var resting = everything()
        resting.live = false
        let plan = audioPlan(resting)
        XCTAssertFalse(plan.capture || plan.speakerVoice || plan.hapticVoice || plan.micArmed)
        XCTAssertTrue(plan.capMic, "the cap is advertised in the descriptor that opens the session")
    }

    func testTheDefaultsAreMicOffSpeakerOn() {
        let facts = AudioFacts(
            routeMic: true,
            routeSpeaker: true,
            host: HostAudioVerdict(mic: true, speaker: true, hapticAudio: false),
            live: true,
            micPermitted: true
        )
        let plan = audioPlan(facts)
        XCTAssertFalse(plan.capMic)
        XCTAssertTrue(plan.capSpeaker && plan.speakerVoice)
    }

    // MARK: - The chip

    func testTheChipHidesLivesOrMutesAllOrNothing() {
        XCTAssertEqual(micIndicator(armed: 0, delivering: 0), .hidden)
        XCTAssertEqual(micIndicator(armed: 2, delivering: 1), .live, "a mixed set reads live")
        XCTAssertEqual(micIndicator(armed: 2, delivering: 0), .muted)
        XCTAssertEqual(micToggleAll(.hidden), .nothing)
        XCTAssertEqual(micToggleAll(.live), .muteAll, "a tap on a mixed set mutes everything")
        XCTAssertEqual(micToggleAll(.muted), .unmuteAll)
    }
}
