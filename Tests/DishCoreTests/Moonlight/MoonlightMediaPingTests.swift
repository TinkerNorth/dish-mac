// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// The pings that keep a host's media ports open: the payload verbatim, the
/// sequence after it, the legacy word for a host that named none.
final class MoonlightMediaPingTests: XCTestCase {

    func testALiveSunshinePayloadRidesVerbatimWithTheSequenceAfterIt() {
        XCTAssertEqual(
            hexString(MoonlightMediaPing.ssPing(payload: "68A75BBEEEA86826", sequence: 0)),
            "3638413735424245454541383638323600000000"
        )
        XCTAssertEqual(
            hexString(MoonlightMediaPing.ssPing(payload: "988E4FC7E070A22F", sequence: 0)),
            "3938384534464337453037304132324600000000"
        )
        XCTAssertEqual(
            hexString(MoonlightMediaPing.ssPing(payload: "68A75BBEEEA86826", sequence: 0x0102_0304).suffix(4)),
            "04030201",
            "little-endian"
        )
    }

    func testThePayloadIsPaddedOrCutToSixteenBytes() {
        XCTAssertEqual(hexString(MoonlightMediaPing.ssPing(payload: "abc", sequence: 1)), "61626300000000000000000000000000" + "01000000")
        XCTAssertEqual(MoonlightMediaPing.ssPing(payload: "0123456789abcdefXYZ", sequence: 0).prefix(16), Data("0123456789abcdef".utf8))
        XCTAssertEqual(MoonlightMediaPing.ssPing(payload: "", sequence: 9).count, MoonlightMediaPing.pingLength)
    }

    func testTheLegacyPingAndWhatCountsAsUsable() {
        XCTAssertEqual(hexString(MoonlightMediaPing.legacy), "50494e47")
        XCTAssertTrue(MoonlightMediaPing.usable("68A75BBEEEA86826"))
        XCTAssertFalse(MoonlightMediaPing.usable(""))
    }
}
