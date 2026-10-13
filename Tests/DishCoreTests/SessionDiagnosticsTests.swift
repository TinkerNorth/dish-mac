// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// Every answer the ack gives has an Unknown, because a session is live
/// before its first enriched ack.
final class SessionDiagnosticsTests: XCTestCase {

    func testTheEpochAgreesOnlyWhenTheHostSaysWhatWeApplied() {
        XCTAssertEqual(epochAgreement(hostEpoch: nil, appliedEpoch: 3), .unknown)
        XCTAssertEqual(epochAgreement(hostEpoch: 3, appliedEpoch: 3), .inStep)
        XCTAssertEqual(epochAgreement(hostEpoch: 4, appliedEpoch: 3), .diverged)
    }

    func testTheBitmapAgreesOnlyWhenItMatchesTheConfirmedSet() {
        XCTAssertEqual(bitmapAgreement(hostBitmap: nil, confirmedBitmap: 0b1), .unknown)
        XCTAssertEqual(bitmapAgreement(hostBitmap: 0b1, confirmedBitmap: 0b1), .inStep)
        XCTAssertEqual(bitmapAgreement(hostBitmap: 0b11, confirmedBitmap: 0b1), .diverged)
    }

    func testTheBitmapNamesItsIndicesLowestFirstAndInsideSixteen() {
        XCTAssertEqual(bitmapIndices(0), [])
        XCTAssertEqual(bitmapIndices(0b1000_0000_0000_0101), [0, 2, 15])
        XCTAssertTrue(bitmapHasIndex(0b100, 2))
        XCTAssertFalse(bitmapHasIndex(0b100, 1))
        XCTAssertFalse(bitmapHasIndex(0xFFFF, 16), "past the wire's width is never set")
        XCTAssertFalse(bitmapHasIndex(0xFFFF, -1))
    }

    func testStreamingReadsTheIndexOutOfTheHostsBitmap() {
        XCTAssertEqual(streamingOf(hostBitmap: nil, controllerIndex: 0), .unknown)
        XCTAssertEqual(streamingOf(hostBitmap: 0b1, controllerIndex: 0), .yes)
        XCTAssertEqual(streamingOf(hostBitmap: 0b1, controllerIndex: 1), .no)
    }

    func testTheBackendByteHasThreeAnswers() {
        XCTAssertEqual(hostBackendOf(nil), .unknown)
        XCTAssertEqual(hostBackendOf(true), .available)
        XCTAssertEqual(hostBackendOf(false), .unavailable)
    }

    func testTheAdvertisedCapsComeBackInWireBitOrder() {
        XCTAssertEqual(advertisedCaps(0), [])
        let word = ProtocolConstants.capRumble | ProtocolConstants.capMotion | ProtocolConstants.capPlayerLeds | ProtocolConstants
            .capHapticAudio
        XCTAssertEqual(advertisedCaps(word), [.rumble, .motion, .playerLeds, .hapticAudio])
        XCTAssertEqual(advertisedCaps(0xFFFF), WireCap.allCases, "every bit the wire names, nothing else")
    }

    func testEveryWireCapHasItsOwnBit() {
        let bits = WireCap.allCases.map(wireCapBit)
        XCTAssertEqual(Set(bits).count, bits.count)
        XCTAssertEqual(bits, bits.sorted(), "declaration order is wire-bit order")
    }
}
