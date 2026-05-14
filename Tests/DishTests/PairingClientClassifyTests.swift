// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import Dish

/// Pins the `PairingClient.classify` contract. Mirrors the
/// `unreachable-vs-auth` distinction that dish-android PR #43 introduced in
/// `SatelliteConnectionManager`. These cases are what stops a moved server
/// from trapping the user behind an unanswerable PIN prompt.
final class PairingClientClassifyTests: XCTestCase {

    func testSuccessRequiresOkAndSharedKey() {
        var r = PairResponse()
        r.ok = true
        r.sharedKey = "abcd"
        r.reachable = true
        XCTAssertEqual(PairingClient.classify(r), .success(sharedKeyHex: "abcd"))
    }

    func testReachableButNotOkIsAuthRequired() {
        var r = PairResponse()
        r.ok = false
        r.reachable = true
        r.error = "bad pin"
        XCTAssertEqual(PairingClient.classify(r), .authRequired)
    }

    func testUnreachableSurfacesNetworkError() {
        var r = PairResponse()
        r.ok = false
        r.reachable = false
        r.error = "connect timeout"
        XCTAssertEqual(
            PairingClient.classify(r),
            .unreachable("connect timeout")
        )
    }

    func testUnreachableWithNoErrorFallsBackToDefaultMessage() {
        var r = PairResponse()
        r.ok = false
        r.reachable = false
        XCTAssertEqual(
            PairingClient.classify(r),
            .unreachable("Server unreachable")
        )
    }

    func testOkButMissingSharedKeyIsNotSuccess() {
        // Defensive: a server that says ok=true but forgets to send a key
        // should fall through to authRequired (since we did reach it), not
        // success. Otherwise we'd cache an empty string as the shared key
        // and silently break every subsequent reconnect.
        var r = PairResponse()
        r.ok = true
        r.sharedKey = nil
        r.reachable = true
        XCTAssertEqual(PairingClient.classify(r), .authRequired)
    }

    func testEmptySharedKeyIsNotSuccess() {
        var r = PairResponse()
        r.ok = true
        r.sharedKey = ""
        r.reachable = true
        XCTAssertEqual(PairingClient.classify(r), .authRequired)
    }

    // MARK: - Decoded responses default to reachable=false

    func testJsonDecodeDefaultsReachableToFalse() throws {
        // PairResponse Decodable omits `reachable` so a fresh server response
        // decodes to reachable=false. PairingClient.pair flips it to true
        // after a successful decode; if we ever drop that flip, every pair
        // response would silently classify as unreachable.
        let json = Data(#"{"ok":true,"sharedKey":"deadbeef"}"#.utf8)
        let r = try JSONDecoder().decode(PairResponse.self, from: json)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.sharedKey, "deadbeef")
        XCTAssertFalse(r.reachable)
    }
}
