// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// Contract §Versioning as executable rules: the settled version keys the
/// frames, an overlapping 409 is a re-offer, and only a disjoint range or an
/// unreadable body ends the attempt.
final class ProtocolNegotiationTests: XCTestCase {

    private let ours = ProtocolConstants.protocolVersion
    private let floor = ProtocolConstants.protocolVersionMin

    // MARK: - The 200 path

    func testAnEchoOfOurOfferSettlesCurrent() {
        let outcome = settleAccepted(echoedVersion: ours)
        XCTAssertEqual(outcome, ProtocolOutcome(verdict: .settled, settledVersion: ours, satelliteBehind: false))
        XCTAssertEqual(compatForOutcome(outcome), .current)
    }

    func testAnEchoAboveOurOfferIsClampedToWhatWeEncode() {
        let outcome = settleAccepted(echoedVersion: ours + 5)
        XCTAssertEqual(outcome.settledVersion, ours)
        XCTAssertFalse(outcome.satelliteBehind)
    }

    func testAnOlderEchoSettlesOnTheSatellitesVersionWithTheSoftHint() {
        let outcome = settleAccepted(echoedVersion: 1)
        XCTAssertEqual(outcome, ProtocolOutcome(verdict: .settled, settledVersion: 1, satelliteBehind: true))
        XCTAssertEqual(compatForOutcome(outcome), .satelliteUpdateAvailable)
        XCTAssertFalse(ProtocolConstants.settledSpeaksV2(outcome.settledVersion), "a v1 session streams the 16-byte frame")
    }

    func testAnEchoBelowOurFloorIsClampedToTheFloor() {
        XCTAssertEqual(settleAccepted(echoedVersion: 0).settledVersion, floor)
        XCTAssertEqual(settleAccepted(echoedVersion: -3).settledVersion, floor)
        let raisedFloor = ClientProtocolRange(version: 3, floor: 2)
        XCTAssertEqual(settleAccepted(echoedVersion: 1, client: raisedFloor).settledVersion, 2)
    }

    // MARK: - The 409 path

    func testAnUnreadableBodyIsUnusableAndBlamesNoOne() {
        XCTAssertEqual(settleRejected(supported: 0, supportedMin: 0).verdict, .unusable)
        XCTAssertEqual(settleRejected(supported: 3, supportedMin: 0).verdict, .unusable)
        XCTAssertEqual(settleRejected(supported: 0, supportedMin: 1).verdict, .unusable)
        XCTAssertEqual(settleRejected(supported: 1, supportedMin: 3).verdict, .unusable, "an inverted range")
        XCTAssertEqual(compatForOutcome(settleRejected(supported: 0, supportedMin: 0)), .unknown)
    }

    func testASatelliteFloorAboveOurCeilingMeansUpdateDish() {
        let outcome = settleRejected(supported: ours + 2, supportedMin: ours + 1)
        XCTAssertEqual(outcome.verdict, .updateDish)
        XCTAssertEqual(compatForOutcome(outcome), .dishUpdateRequired)
        XCTAssertTrue(protocolCompatBlocks(.dishUpdateRequired))
    }

    func testASatelliteCeilingBelowOurFloorMeansUpdateSatellite() {
        // Versions start at 1, so with the build's floor of 1 no readable
        // range can sit below it; the arm fires once the floor rises.
        XCTAssertEqual(floor, 1)
        let raisedFloor = ClientProtocolRange(version: 3, floor: 2)
        let outcome = settleRejected(supported: 1, supportedMin: 1, client: raisedFloor)
        XCTAssertEqual(outcome.verdict, .updateSatellite)
        XCTAssertEqual(compatForOutcome(outcome), .satelliteUpdateRequired)
        XCTAssertTrue(protocolCompatBlocks(.satelliteUpdateRequired))
    }

    func testTheClientRangeDefaultsToTheBuilds() {
        XCTAssertEqual(ClientProtocolRange.current, ClientProtocolRange(version: ours, floor: floor))
    }

    func testAnOverlappingRangeReOffersTheSatellitesCeiling() {
        let outcome = settleRejected(supported: 2, supportedMin: 1)
        XCTAssertEqual(outcome, ProtocolOutcome(verdict: .retryLower, settledVersion: 2))
        XCTAssertEqual(compatForOutcome(outcome), .unknown, "the re-offer decides one round trip later")
    }

    func testAReOfferNeverExceedsOurOwnVersion() {
        // A 409 with a ceiling at or above our offer is a server bug; the
        // reducer still answers something we can send.
        XCTAssertEqual(settleRejected(supported: ours + 1, supportedMin: 1).settledVersion, ours)
    }

    // MARK: - Terminal verdicts and the chip

    func testOnlyTheDisjointAndUnreadableVerdictsEndTheAttempt() {
        XCTAssertTrue(protocolVerdictIsTerminal(.updateDish))
        XCTAssertTrue(protocolVerdictIsTerminal(.updateSatellite))
        XCTAssertTrue(protocolVerdictIsTerminal(.unusable))
        XCTAssertFalse(protocolVerdictIsTerminal(.settled))
        XCTAssertFalse(protocolVerdictIsTerminal(.retryLower))
    }

    func testOnlyTheRequiredStatesBlock() {
        XCTAssertFalse(protocolCompatBlocks(.unknown))
        XCTAssertFalse(protocolCompatBlocks(.current))
        XCTAssertFalse(protocolCompatBlocks(.satelliteUpdateAvailable))
    }
}
